import Foundation

/// Returns inspection text only while its original model-selection revision is current.
struct StudioInspectionClient: Sendable {
    let transport: @Sendable (URLRequest) async throws -> UpstreamResponse

    init(transport: (@Sendable (URLRequest) async throws -> UpstreamResponse)? = nil) {
        let client = InspectorHTTPClient()
        self.transport = transport ?? { try await client.send($0) }
    }

    func read(path: String, width: Int = 80, routing: @Sendable () async -> ModelControlRoutingState) async throws
        -> [StudioInspectionRow]
    {
        let data = try await fetch(path: path, routing: routing)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let raw = String(decoding: pretty, as: UTF8.self).components(separatedBy: "\n").map { StudioInspectionRow($0) }
        if path == "v1/inspector/model", let map = StudioLayerMap.rows(object: object, width: width) {
            return map + ["", "TENSOR DETAILS", ""] + raw
        }
        return raw
    }

    func fetch(path: String, timeout: TimeInterval = 30, routing: @Sendable () async -> ModelControlRoutingState)
        async throws -> Data
    {
        let original = await routing()
        var request = URLRequest(url: original.url.appendingPathComponent(path))
        request.timeoutInterval = timeout
        let response = try await transport(request)
        try Task.checkCancellation()
        let current = await routing()
        try Task.checkCancellation()
        guard current.revision == original.revision else {
            throw ConfigurationError("The model connection changed during inspection. Request a fresh inspection.")
        }
        guard (200..<300).contains(response.status) else {
            throw ConfigurationError("Midnight returned HTTP \(response.status).")
        }
        return response.body
    }
}
