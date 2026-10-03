import Foundation

/// One explicit arm observes the next matching inference request from any authorized client.
struct StudioRecordingClient: Sendable {
    struct Armed: Sendable {
        let id: String
        let origin: URL
        let revision: String
        let selection: StudioActivationSelection
        let topology: Data
    }

    struct Update: Sendable {
        let status: String
        let message: String?
        let capture: StudioActivationCapture?
    }

    private let transport: @Sendable (URLRequest) async throws -> UpstreamResponse

    init(transport: (@Sendable (URLRequest) async throws -> UpstreamResponse)? = nil) {
        let client = InspectorHTTPClient()
        self.transport = transport ?? { try await client.send($0) }
    }

    func arm(routing: @Sendable () async -> ModelControlRoutingState) async throws -> Armed {
        let route = await routing()
        let topology = try await send(URLRequest(url: route.url.appendingPathComponent("v1/inspector/model")))
        let descriptor = try JSONDecoder().decode(StudioActivationDescriptor.self, from: topology)
        let initial = try descriptor.selection(question: "External chat recording", maxTokens: 32)
        let bytesPerLayer =
            initial.sites.count * ((initial.maxTokens + 1) * 512 + 4096)
            + (initial.maxTokens + 1) * 4096 + 8192
        let layerLimit = max(0, (initial.maxCaptureBytes - 512 * 1024) / bytesPerLayer)
        guard layerLimit > 0 else {
            throw ConfigurationError("The model's capture budget is too small for a chat recording.")
        }
        let selection = StudioActivationSelection(
            question: initial.question, maxTokens: initial.maxTokens, model: initial.model,
            runtimeGeneration: initial.runtimeGeneration, layers: Array(initial.layers.prefix(layerLimit)),
            sites: initial.sites, tokenPositions: initial.tokenPositions, capture: initial.capture,
            maxCaptureBytes: initial.maxCaptureBytes)
        try await checkRouting(route.revision, routing: routing)
        var request = URLRequest(url: route.url.appendingPathComponent("v1/inspector/recordings"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": selection.model, "runtimeGeneration": selection.runtimeGeneration,
            "layers": selection.layers, "sites": selection.sites,
            "maxTokens": selection.maxTokens, "maxCaptureBytes": selection.maxCaptureBytes,
        ])
        // Once POST succeeds, return its handle even if cancellation arrived during
        // transport. The owner can then DELETE the arm on the original connection.
        let data = try await send(request, checkCancellationAfter: false)
        let session = try JSONDecoder().decode(Session.self, from: data)
        guard UUID(uuidString: session.id) != nil, ["armed", "recording"].contains(session.status) else {
            throw ConfigurationError(session.message ?? "Midnight did not arm an activation recording.")
        }
        return Armed(
            id: session.id, origin: route.url, revision: route.revision, selection: selection, topology: topology)
    }

    func poll(_ recording: Armed, routing: @Sendable () async -> ModelControlRoutingState) async throws -> Update {
        try await checkRouting(recording.revision, routing: routing)
        let data = try await send(URLRequest(url: endpoint(recording)))
        try await checkRouting(recording.revision, routing: routing)
        let session = try JSONDecoder().decode(Session.self, from: data)
        guard session.id == recording.id,
            ["armed", "recording", "completed", "cancelled", "failed"].contains(session.status)
        else { throw ConfigurationError("Midnight returned a different or invalid recording session.") }
        guard session.status == "completed" else {
            return Update(status: session.status, message: session.message, capture: nil)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let trace = object?["trace"], let model = object?["model"] else {
            throw ConfigurationError("The completed recording is missing its trace or model snapshot.")
        }
        let capture = try Self.decodeCapture(
            topology: JSONSerialization.data(withJSONObject: model),
            trace: JSONSerialization.data(withJSONObject: trace),
            id: session.id, createdAt: session.createdAt, cachedPromptTokenCount: session.cachedPromptTokenCount,
            expectedModel: recording.selection.model, layers: recording.selection.layers,
            sites: recording.selection.sites)
        guard capture.maxTokens == recording.selection.maxTokens else {
            throw ConfigurationError("Midnight returned a different recording token limit.")
        }
        return Update(status: session.status, message: session.message, capture: capture)
    }

    /// A detached cleanup task calls this even when the UI operation is cancelled.
    func cancel(_ recording: Armed) async throws {
        var request = URLRequest(url: endpoint(recording))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        _ = try await send(request)
    }

    static func decodeCapture(
        topology: Data, trace data: Data, id: String, createdAt: Double, cachedPromptTokenCount: Int?,
        expectedModel: String, layers: [Int], sites: [String]
    ) throws -> StudioActivationCapture {
        let descriptor = try JSONDecoder().decode(StudioActivationDescriptor.self, from: topology)
        let trace = try JSONDecoder().decode(StudioActivationTrace.self, from: data)
        guard UUID(uuidString: id) != nil, createdAt.isFinite, createdAt >= 0,
            descriptor.id == expectedModel, trace.model == expectedModel,
            descriptor.layerCount == descriptor.layers.count, descriptor.layers.count <= 2048,
            descriptor.layers.allSatisfy({ $0.index >= 0 }),
            Set(descriptor.layers.map(\.index)).count == descriptor.layers.count,
            !layers.isEmpty, layers.count <= 128, Set(layers).count == layers.count,
            Set(layers).isSubset(of: Set(descriptor.layers.map(\.index))),
            !sites.isEmpty, Set(sites).count == sites.count,
            Set(sites).isSubset(of: ["layer_input", "after_attention"]),
            trace.question.isEmpty, trace.promptTokenCount > 0, trace.generatedTokenCount >= 0,
            (1...64).contains(trace.maxTokens), trace.tokens.count <= trace.maxTokens + 1,
            cachedPromptTokenCount.map({ $0 >= 0 && $0 <= trace.promptTokenCount }) ?? true
        else { throw ConfigurationError("The recording has invalid model, selection, or token metadata.") }
        let expectedSites = Set(layers.flatMap { index in sites.map { "\(index):\($0)" } })
        let receivedSites = trace.layers.map { "\($0.index):\($0.site)" }
        let positions = trace.tokens.map(\.position)
        let observedCount = min(trace.maxTokens, trace.generatedTokenCount)
        guard trace.promptTokenCount <= Int.max - observedCount else {
            throw ConfigurationError("The recording's token positions exceed the supported range.")
        }
        let expectedPositions = Array((trace.promptTokenCount - 1)..<(trace.promptTokenCount + observedCount))
        guard positions == expectedPositions, Set(receivedSites) == expectedSites,
            receivedSites.count == expectedSites.count,
            positions == positions.sorted(), Set(positions).count == positions.count,
            trace.tokens.allSatisfy({ token in
                token.id >= 0 && token.position >= 0 && token.position - trace.promptTokenCount < trace.maxTokens
                    && token.phase == (token.position < trace.promptTokenCount ? "prompt" : "answer")
            })
        else { throw ConfigurationError("The recording has invalid token coordinates or layer sites.") }
        for layer in trace.layers {
            let samples = layer.samples.map(\.tokenIndex)
            guard samples == expectedPositions,
                layer.samples.allSatisfy({ $0.rms.isFinite && $0.rms >= 0 })
            else { throw ConfigurationError("The recording has invalid activation samples.") }
        }
        try trace.validateComponents(selected: Set(layers), positions: expectedPositions)
        return StudioActivationCapture(
            model: trace.model, question: trace.question, answer: trace.answer,
            promptTokenCount: trace.promptTokenCount, tokens: trace.tokens, layers: trace.layers,
            stopReason: trace.stopReason, maxTokens: trace.maxTokens,
            totalLayerCount: descriptor.layerCount, topologyData: topology, captureData: data,
            components: trace.components, expertRouting: trace.expertRouting,
            recordingID: id, createdAt: createdAt, cachedPromptTokenCount: cachedPromptTokenCount)
    }

    private struct Session: Decodable {
        let id: String
        let status: String
        let createdAt: Double
        let message: String?
        let cachedPromptTokenCount: Int?
    }

    private func endpoint(_ recording: Armed) -> URL {
        recording.origin.appendingPathComponent("v1/inspector/recordings").appendingPathComponent(recording.id)
    }

    private func checkRouting(
        _ revision: String, routing: @Sendable () async -> ModelControlRoutingState
    ) async throws {
        try Task.checkCancellation()
        guard await routing().revision == revision else {
            throw ConfigurationError("The model connection changed. Arm a recording on the current connection.")
        }
    }

    private func send(_ request: URLRequest, checkCancellationAfter: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        let response = try await transport(request)
        if checkCancellationAfter { try Task.checkCancellation() }
        guard response.body.count <= InspectorHTTPClient.maximumResponseBytes else {
            throw ConfigurationError("The recording response exceeded the 8 MiB limit.")
        }
        guard (200..<300).contains(response.status) else {
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw ConfigurationError(
                "Midnight returned HTTP \(response.status). \(message.map { String($0.prefix(600)) } ?? "")")
        }
        return response.body
    }
}
