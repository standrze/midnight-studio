import CoreFoundation
import CryptoKit
import Foundation

struct ModelControlConfiguration: Sendable {
    let executableURL: URL
    let modelRoots: [URL]
    let stateDirectory: URL
    var managedPort: Int = 8082
    var externalURL: URL = URL(string: "http://127.0.0.1:8080")!
    var startupTimeout: TimeInterval = 600
    var pollInterval: TimeInterval = 0.5
    var stopTimeout: TimeInterval = 8

    var managedURL: URL { URL(string: "http://127.0.0.1:\(managedPort)")! }
}

struct ModelControlProfile: Codable, Sendable, Equatable {
    var modelID: String
    var servedModelName: String
    var contextLength: Int
    var maximumTokens: Int
    var prefillStepSize: Int
    var kvCompression: String
    var engine: String
}

struct ModelControlModel: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let path: String
    let architecture: String
    let layerCount: Int?
    let architectureContextLength: Int?
    let weightBytes: Int?
    let quantization: String?
    let defaults: ModelControlProfile
    let supported: Bool
    let supportsKVCompression: Bool
    let warning: String?
}

struct ModelControlError: LocalizedError, Sendable {
    let code: String
    let message: String
    let status: Int
    init(_ message: String, code: String = "invalid_profile", status: Int = 400) {
        self.message = message
        self.code = code
        self.status = status
    }
    var errorDescription: String? { message }
}

/// Only checkpoint metadata is read. Weights are never opened by the catalog.
struct ModelControlCatalog: Sendable {
    let roots: [URL]
    private let maximumMetadataBytes = 2 * 1024 * 1024

    func models() -> [ModelControlModel] {
        let fm = FileManager.default
        var models: [ModelControlModel] = []
        var visited = Set<String>()
        for configuredRoot in roots {
            let root = configuredRoot.standardizedFileURL.resolvingSymlinksInPath()
            var queue: [(URL, Int)] = [(root, 0)]
            var inspected = 0
            while !queue.isEmpty && inspected < 500 {
                let (directory, depth) = queue.removeFirst()
                inspected += 1
                let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
                guard Self.contains(canonical, in: root), visited.insert(canonical.path).inserted else { continue }
                if let model = try? readModel(at: canonical) {
                    models.append(model)
                    continue
                }
                guard depth < 3, let children = try? fm.contentsOfDirectory(
                    at: canonical, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children.sorted(by: { $0.path < $1.path }) {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    queue.append((child, depth + 1))
                }
            }
        }
        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func validate(_ profile: ModelControlProfile) throws -> ModelControlModel {
        guard let model = models().first(where: { $0.id == profile.modelID }) else {
            throw ModelControlError("That model is no longer available in the configured model folders. Refresh the catalog.", code: "unknown_model", status: 404)
        }
        guard model.supported else {
            throw ModelControlError(model.warning ?? "This folder is not a supported chat checkpoint.")
        }
        guard !profile.servedModelName.isEmpty, profile.servedModelName.utf8.count <= 128,
              profile.servedModelName == profile.servedModelName.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.servedModelName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelControlError("Use a served model name between 1 and 128 bytes, without leading/trailing spaces or control characters.")
        }
        guard (2...16_777_216).contains(profile.contextLength) else {
            throw ModelControlError("Context length must be between 2 and 16,777,216 tokens.")
        }
        if let maximum = model.architectureContextLength, profile.contextLength > maximum {
            throw ModelControlError("Context length exceeds this checkpoint's architectural limit of \(maximum) tokens.")
        }
        guard profile.maximumTokens > 0, profile.maximumTokens < profile.contextLength else {
            throw ModelControlError("Maximum output tokens must be positive and smaller than the context window, leaving room for a prompt.")
        }
        guard (1...8192).contains(profile.prefillStepSize) else {
            throw ModelControlError("Prefill step size must be between 1 and 8,192 tokens.")
        }
        guard ["none", "affine8", "affine4", "turbo8v4"].contains(profile.kvCompression) else {
            throw ModelControlError("KV compression must be none, affine8, affine4, or turbo8v4.")
        }
        guard profile.kvCompression == "none" || model.supportsKVCompression else {
            throw ModelControlError("KV compression is supported only for Laguna and Mistral-family text models; choose none for this checkpoint.")
        }
        guard ["auto", "metal", "cpu"].contains(profile.engine) else {
            throw ModelControlError("Choose auto, metal, or cpu for this macOS runner.")
        }
        return model
    }

    private func readModel(at directory: URL) throws -> ModelControlModel {
        let root = try metadata(directory.appendingPathComponent("config.json"), within: directory)
        let text = root["text_config"] as? [String: Any] ?? root
        let architectures = (root["architectures"] as? [String] ?? []).joined(separator: ", ")
        let type = (text["model_type"] as? String ?? root["model_type"] as? String ?? architectures).lowercased()
        let layerCount = integer(text["num_hidden_layers"]) ?? integer(text["n_layer"])
        let architecturalLimit = integer(text["max_position_embeddings"]) ?? integer(text["n_positions"])
            ?? integer(text["max_sequence_length"]) ?? integer(text["seq_length"])
        let id = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = directory.lastPathComponent
        var local: [String: Any] = [:]
        var warning: String?
        let localURL = directory.appendingPathComponent("midnight.json")
        if FileManager.default.fileExists(atPath: localURL.path) {
            do {
                local = try metadata(localURL, within: directory)
                let known: Set<String> = ["contextLength", "maximumTokens", "prefillStepSize", "kvCompression"]
                guard Set(local.keys).subtracting(known).isEmpty else { throw ModelControlError("Unknown midnight.json settings.") }
                for key in ["contextLength", "maximumTokens", "prefillStepSize"] where local[key] != nil {
                    guard integer(local[key]) != nil else { throw ModelControlError("Invalid \(key) in midnight.json.") }
                }
                if let compression = local["kvCompression"], !(compression is String) {
                    throw ModelControlError("Invalid kvCompression in midnight.json.")
                }
            } catch { warning = "Checkpoint settings could not be read: \(error.localizedDescription)" }
        }
        let audio = ["audio", "chatterbox", "voxtral", "tokenizer", "dflash"].contains { type.contains($0) || architectures.lowercased().contains($0) }
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("chatterbox.json").path)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
        let weightBytes = files.filter { $0.hasSuffix(".safetensors") }.reduce(0) { total, name in
            let size = (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int.max : sum
        }
        let quantizationConfig = root["quantization"] as? [String: Any] ?? root["quantization_config"] as? [String: Any]
        let quantization: String? = quantizationConfig.map { config in
            let bits = integer(config["bits"]).map { "\($0)-bit" }
            let mode = config["mode"] as? String ?? config["quant_method"] as? String
            return [bits, mode].compactMap { $0 }.joined(separator: " ")
        }
        let supported = !audio && layerCount != nil && hasWeights && warning == nil
        if audio { warning = "This is an audio, tokenizer, or draft checkpoint. Model Control currently loads text generation models." }
        else if !hasWeights { warning = "No local .safetensors weights were found in this checkpoint folder." }
        else if layerCount == nil { warning = "This folder does not declare a text model layer structure." }
        else if architecturalLimit == nil && warning == nil { warning = "No architectural context limit is declared; the runtime will validate this checkpoint when loading." }
        let context = integer(local["contextLength"]) ?? min(architecturalLimit ?? 4096, 32768)
        let supportsKV = ["laguna", "mistral", "mixtral", "ministral"].contains { type.contains($0) }
        let defaults = ModelControlProfile(
            modelID: id, servedModelName: name, contextLength: max(2, context),
            maximumTokens: min(integer(local["maximumTokens"]) ?? 512, max(1, context - 1)),
            prefillStepSize: integer(local["prefillStepSize"]) ?? 512,
            kvCompression: local["kvCompression"] as? String ?? "none", engine: "auto"
        )
        return ModelControlModel(
            id: id, name: name, path: directory.path, architecture: type.isEmpty ? "unknown" : type,
            layerCount: layerCount, architectureContextLength: architecturalLimit,
            weightBytes: hasWeights ? weightBytes : nil, quantization: quantization?.isEmpty == false ? quantization : nil, defaults: defaults,
            supported: supported, supportsKVCompression: supportsKV, warning: warning
        )
    }

    private func metadata(_ url: URL, within directory: URL) throws -> [String: Any] {
        let canonical = url.resolvingSymlinksInPath()
        guard Self.contains(canonical, in: directory),
              let size = try canonical.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumMetadataBytes else { throw ModelControlError("Metadata is outside its model folder or exceeds 2 MiB.") }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: canonical)) as? [String: Any] else {
            throw ModelControlError("Model metadata must be a JSON object.")
        }
        return object
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue > 0, number.doubleValue <= 16_777_216 else { return nil }
        return number.intValue
    }

    static func contains(_ child: URL, in root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
}
