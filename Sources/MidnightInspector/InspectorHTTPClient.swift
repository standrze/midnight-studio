import Foundation

struct UpstreamResponse: Sendable {
    let status: Int
    let body: Data
}

struct InspectorHTTPClient: Sendable {
    static let maximumResponseBytes = 8 * 1024 * 1024
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func authorized(
        _ request: URLRequest, apiKey: String? = ProcessInfo.processInfo.environment["MIDNIGHT_API_KEY"]
    ) -> URLRequest {
        var request = request
        if request.value(forHTTPHeaderField: "Authorization") == nil, let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> UpstreamResponse {
        let request = Self.authorized(request)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConfigurationError("The upstream response was not HTTP.")
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < InspectorHTTPClient.maximumResponseBytes else {
                throw ConfigurationError("The upstream response exceeded the 8 MiB limit.")
            }
            body.append(byte)
        }
        return UpstreamResponse(status: response.statusCode, body: body)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
