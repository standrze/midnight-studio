import Foundation

struct ManagedRuntimeState: Codable, Sendable {
    struct Model: Codable, Sendable { let id: String }
    let instanceID: String?
    let processID: Int32
    let phase: String
    let operationID: String?
    let modelGeneration: UInt64
    let loadedModel: Model?
    let targetModel: String?
    let lastError: String?
}

struct ManagedModelRequest: Codable, Sendable {
    let model: String
    let name: String
    let adapter: String?
    let maxTokens: Int
    let contextLength: Int
    let prefillStepSize: Int
    let kvCompression: String
    let engine: String
}

protocol ModelControlRuntime: Sendable {
    func state(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState
    func load(_ model: ManagedModelRequest, at endpoint: URL, instanceID: String, processID: Int32) async throws
        -> ManagedRuntimeState
    func unload(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState
}

struct ModelControlRuntimeClient: ModelControlRuntime {
    typealias Transport = @Sendable (URLRequest) async throws -> UpstreamResponse
    private let session: URLSession
    private let transport: Transport?
    private let apiKey: String?

    init(apiKey: String? = ProcessInfo.processInfo.environment["MIDNIGHT_API_KEY"], transport: Transport? = nil) {
        self.apiKey = apiKey
        self.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration, delegate: RuntimeNoRedirects(), delegateQueue: nil)
    }

    func state(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        try await request(at: endpoint, path: "v1/runtime", instanceID: instanceID, processID: processID)
    }

    func load(_ model: ManagedModelRequest, at endpoint: URL, instanceID: String, processID: Int32) async throws
        -> ManagedRuntimeState
    {
        // Verify ownership before sending any model mutation to the listening port.
        _ = try await state(at: endpoint, instanceID: instanceID, processID: processID)
        try Task.checkCancellation()
        return try await request(
            at: endpoint, path: "v1/runtime/load", body: JSONEncoder().encode(model), instanceID: instanceID,
            processID: processID)
    }

    func unload(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        _ = try await state(at: endpoint, instanceID: instanceID, processID: processID)
        try Task.checkCancellation()
        return try await request(
            at: endpoint, path: "v1/runtime/unload", body: Data("{}".utf8), instanceID: instanceID, processID: processID
        )
    }

    private func request(at endpoint: URL, path: String, body: Data? = nil, instanceID: String, processID: Int32)
        async throws -> ManagedRuntimeState
    {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request = InspectorHTTPClient.authorized(request, apiKey: apiKey)
        let response: UpstreamResponse
        if let transport {
            response = try await transport(request)
        } else {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let rawResponse = rawResponse as? HTTPURLResponse else {
                throw ModelControlError("Midnight returned a non-HTTP runtime response.")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 64 * 1024 else {
                    throw ModelControlError("Runtime response exceeded its size limit.")
                }
                data.append(byte)
            }
            response = UpstreamResponse(status: rawResponse.statusCode, body: data)
        }
        guard response.body.count <= 64 * 1024 else {
            throw ModelControlError("Runtime response exceeded its size limit.")
        }
        guard response.status == (body == nil ? 200 : 202) else {
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            let detail = (object?["error"] as? [String: Any])?["message"] as? String
            throw ModelControlError(
                detail
                    ?? "Midnight runtime request failed (HTTP \(response.status)). Update the runner if it does not support live model loading.",
                code: response.status == 409 ? "busy" : "runtime_error", status: response.status)
        }
        let value = try JSONDecoder().decode(ManagedRuntimeState.self, from: response.body)
        guard !instanceID.isEmpty, processID > 0, value.instanceID == instanceID, value.processID == processID else {
            throw ModelControlError(
                "The runtime does not match the Midnight process owned by Studio.", code: "runtime_identity_mismatch",
                status: 409)
        }
        return value
    }
}

private final class RuntimeNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
