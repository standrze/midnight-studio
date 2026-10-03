import CryptoKit
import Foundation

struct StudioHubManifest: Codable, Sendable {
    let repository: String
    let commit: String
    let files: [String]
    let sizes: [String: Int64]
    let hashes: [String: String]
}

protocol StudioHubClient: Sendable {
    func manifest(repository: String, revision: String) async throws -> StudioHubManifest
    func download(repository: String, commit: String, file: String, into directory: URL,
                  expectedSize: Int64?, expectedHash: String?) async throws
}

struct StudioHub: StudioHubClient, Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: StudioHubRedirects(), delegateQueue: nil)
    }

    static func validate(repository: String, revision: String) throws {
        let pieces = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ validComponent(String($0)) }),
              (1...128).contains(revision.count), revision.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ validComponent(String($0)) }) else {
            throw ModelControlError("Use a Hugging Face owner/model ID and a branch, tag, or commit revision.")
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96 && value != "." && value != ".." && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }

    func manifest(repository: String, revision: String) async throws -> StudioHubManifest {
        try Self.validate(repository: repository, revision: revision)
        let encoded = revision.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = URL(string: "https://huggingface.co/api/models/\(repository)/revision/\(encoded)?blobs=true")!
        let (bytes, response) = try await session.bytes(for: request(url))
        try check(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw ModelControlError("Hugging Face model metadata exceeds 8 MiB.") }
            data.append(byte)
        }
        return try Self.parseManifest(data, repository: repository)
    }

    static func parseManifest(_ data: Data, repository: String) throws -> StudioHubManifest {
        struct Info: Decodable {
            struct Sibling: Decodable {
                struct LFS: Decodable { var sha256: String?; var size: Int64? }
                var rfilename: String
                var size: Int64?
                var lfs: LFS?
            }
            var sha: String
            var siblings: [Sibling]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.sha.count == 40, info.sha.allSatisfy(\.isHexDigit), info.siblings.count <= 10000 else {
            throw ModelControlError("Hugging Face returned an invalid revision or too many files.")
        }
        let files = info.siblings.filter {
            let name = $0.rfilename
            return validComponent(name) && !name.hasPrefix(".") && name != "studio-source.json" &&
                (name.hasSuffix(".safetensors") || name.hasSuffix(".json") || ["tokenizer.model", "spiece.model", "merges.txt", "vocab.txt", "README.md", "LICENSE"].contains(name))
        }
        guard files.contains(where: { $0.rfilename == "config.json" }),
              files.contains(where: { $0.rfilename.hasSuffix(".safetensors") }),
              Set(files.map(\.rfilename)).count == files.count else {
            throw ModelControlError("This repository needs config.json and safetensors weights at its root. GGUF, pickle weights, and remote Python code are not supported by this importer.")
        }
        return .init(repository: repository, commit: info.sha, files: files.map(\.rfilename).sorted(),
                     sizes: Dictionary(uniqueKeysWithValues: files.compactMap { file in (file.size ?? file.lfs?.size).map { (file.rfilename, $0) } }),
                     hashes: Dictionary(uniqueKeysWithValues: files.compactMap { file in file.lfs?.sha256.map { (file.rfilename, $0) } }))
    }

    func download(repository: String, commit: String, file: String, into directory: URL,
                  expectedSize: Int64? = nil, expectedHash: String? = nil) async throws {
        guard Self.validComponent(file) else { throw ModelControlError("Invalid checkpoint filename.") }
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(file)")!
        let (temporary, response) = try await session.download(for: request(url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response)
        try Task.checkCancellation()
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let expectedSize, expectedSize != Int64(size) { throw ModelControlError("Download size did not match for \(file).") }
        if let expectedHash {
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash.lowercased() else {
                throw ModelControlError("Download checksum did not match for \(file).")
            }
        }
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(file))
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModelControlError("Hugging Face returned HTTP \(status). Check the repository and revision. For gated or private models, accept access on Hugging Face and launch Studio with HF_TOKEN.", code: "hub_error", status: 502)
        }
    }
}

private final class StudioHubRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              ["huggingface.co", "hf.co", "xethub.hf.co", "amazonaws.com", "cloudfront.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            completionHandler(nil); return
        }
        var next = request
        if host != "huggingface.co" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}
