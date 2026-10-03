import Foundation

/// A bounded, measured residual trace.
///
/// Playback never issues model requests.
struct StudioActivationCapture: Sendable {
    struct Token: Decodable, Sendable {
        let id: Int
        let text: String
        let position: Int
        let phase: String
    }

    struct Sample: Decodable, Sendable {
        let tokenIndex: Int
        let rms: Double
    }

    struct Layer: Decodable, Sendable {
        let index: Int
        let site: String
        let samples: [Sample]
    }

    struct RoutingSample: Decodable, Sendable {
        let tokenIndex: Int
        let expertIDs: [Int]
        let weights: [Double]
    }

    struct Routing: Decodable, Sendable {
        let index: Int
        let path: String
        let expertCount: Int
        let samples: [RoutingSample]
    }

    let model: String
    let question: String
    let answer: String
    let promptTokenCount: Int
    let tokens: [Token]
    let layers: [Layer]
    let stopReason: String
    let maxTokens: Int
    let totalLayerCount: Int
    let topologyData: Data
    /// Original /v1/inspector/trace response, preserving all measured fields.
    let captureData: Data
    var components: [Layer]? = nil
    var expertRouting: [Routing]? = nil
    var recordingID: String? = nil
    var createdAt: Double? = nil
    var cachedPromptTokenCount: Int? = nil

    var capturedLayerIndices: [Int] { Set(layers.map(\.index)).sorted() }
    var capturedSites: [String] {
        ["layer_input", "after_attention"].filter { site in layers.contains { $0.site == site } }
    }
    var playableTokenIndices: [Int] { Set(layers.flatMap { $0.samples.map(\.tokenIndex) }).sorted() }
    var selectionNote: String {
        let count = capturedLayerIndices.count
        if count == totalLayerCount { return "Captured all \(count) layers." }
        return "Captured the first \(count) of \(totalLayerCount) layers within Midnight's capture limits."
    }

    func rms(layerIndex: Int, site: String, tokenIndex: Int) -> Double? {
        layers.first { $0.index == layerIndex && $0.site == site }?.samples.first { $0.tokenIndex == tokenIndex }?.rms
    }

    /// A fixed scale across the complete playback; unmeasured samples remain absent.
    func maxRMS(site: String) -> Double {
        layers.filter { $0.site == site }.flatMap(\.samples).map(\.rms).max() ?? 0
    }
}

/// Captures only explicit layers, sites, and token positions from one routing revision.
struct StudioActivationCaptureClient: Sendable {
    let transport: @Sendable (URLRequest) async throws -> UpstreamResponse

    init(transport: (@Sendable (URLRequest) async throws -> UpstreamResponse)? = nil) {
        let client = InspectorHTTPClient()
        self.transport = transport ?? { try await client.send($0) }
    }

    func record(
        question: String, maxTokens: Int = 8, expectedRevision: String,
        routing: @Sendable () async -> ModelControlRoutingState
    ) async throws -> StudioActivationCapture {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 16_384 else {
            throw ConfigurationError("Enter a short question, up to 16 KiB, to record activations.")
        }
        guard (1...64).contains(maxTokens) else {
            throw ConfigurationError("Choose an activation recording limit from 1 to 64 output tokens.")
        }
        let original = await routing()
        try checkRevision(original, expected: expectedRevision)
        let topologyData = try await responseData(
            URLRequest(url: original.url.appendingPathComponent("v1/inspector/model")))
        let descriptor = try JSONDecoder().decode(StudioActivationDescriptor.self, from: topologyData)
        let selection = try descriptor.selection(question: question, maxTokens: maxTokens)
        try checkRevision(await routing(), expected: expectedRevision)

        var request = URLRequest(url: original.url.appendingPathComponent("v1/inspector/trace"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(selection)
        request.timeoutInterval = 300
        let captureData = try await responseData(request)
        try checkRevision(await routing(), expected: expectedRevision)
        let trace = try JSONDecoder().decode(StudioActivationTrace.self, from: captureData)
        try trace.validate(selection: selection, descriptor: descriptor)
        return StudioActivationCapture(
            model: trace.model, question: trace.question, answer: trace.answer,
            promptTokenCount: trace.promptTokenCount, tokens: trace.tokens, layers: trace.layers,
            stopReason: trace.stopReason, maxTokens: trace.maxTokens,
            totalLayerCount: descriptor.layers.count, topologyData: topologyData, captureData: captureData)
    }

    private func checkRevision(_ state: ModelControlRoutingState, expected: String) throws {
        try Task.checkCancellation()
        guard state.revision == expected else {
            throw ConfigurationError(
                "The model connection changed during recording. Record again with the current model.")
        }
    }

    private func responseData(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let response = try await transport(request)
        try Task.checkCancellation()
        guard response.body.count <= InspectorHTTPClient.maximumResponseBytes else {
            throw ConfigurationError("The activation response exceeded the 8 MiB limit.")
        }
        guard (200..<300).contains(response.status) else {
            let error = try? JSONDecoder().decode(StudioActivationErrorEnvelope.self, from: response.body)
            let detail = error.map { " \(String($0.error.message.prefix(600)))" } ?? ""
            throw ConfigurationError("Midnight returned HTTP \(response.status).\(detail)")
        }
        return response.body
    }
}

struct StudioActivationDescriptor: Decodable, Sendable {
    struct Layer: Decodable, Sendable { let index: Int }
    struct Capabilities: Decodable, Sendable {
        struct Observation: Decodable, Sendable {
            let site: String
            let hiddenSize: Int
        }
        let version: Int
        let captureModes: [String]
        let maxSelectedLayers: Int
        let maxPrefillTokens: Int
        let maxDecodeTokens: Int
        let maxCaptureBytes: Int
        let observationPoints: [Observation]
        var recordingComponents: [String]? = nil
    }
    let id: String
    let traceSupported: Bool
    let traceReason: String?
    let runtimeGeneration: UInt64?
    let traceCapabilities: Capabilities?
    let layerCount: Int
    let layers: [Layer]

    func selection(question: String, maxTokens: Int) throws -> StudioActivationSelection {
        guard traceSupported else {
            throw ConfigurationError(traceReason ?? "This model does not support activation recording.")
        }
        guard !id.isEmpty, !layers.isEmpty, layers.count <= 2048, layerCount == layers.count,
            layers.allSatisfy({ $0.index >= 0 }), Set(layers.map(\.index)).count == layers.count,
            let runtimeGeneration, let capabilities = traceCapabilities,
            capabilities.version == 1, capabilities.captureModes.contains("summary"),
            capabilities.maxSelectedLayers > 0, capabilities.maxPrefillTokens > 0,
            capabilities.maxDecodeTokens > 0, capabilities.maxCaptureBytes > 0
        else {
            throw ConfigurationError("Refresh a Midnight model with explicit inspection capabilities before recording.")
        }
        let sites = ["layer_input", "after_attention"].filter { site in
            capabilities.observationPoints.contains { $0.site == site && (1...131_072).contains($0.hiddenSize) }
        }
        guard !sites.isEmpty else {
            throw ConfigurationError("The model exposes no supported residual observation sites.")
        }
        let tokenLimit = min(maxTokens, capabilities.maxDecodeTokens)
        // The native summary budget includes 512 bytes per sample plus position/point
        // metadata. Reserve room below the HTTP client's 8 MiB response bound.
        let budget = min(capabilities.maxCaptureBytes, 4 * 1024 * 1024)
        let bytesPerLayer = sites.count * ((tokenLimit + 1) * (512 + 48) + 1024)
        let layerLimit = min(capabilities.maxSelectedLayers, 128, budget / bytesPerLayer)
        guard layerLimit > 0 else {
            throw ConfigurationError(
                "The model's capture budget cannot hold this recording. Reduce its output token limit.")
        }
        return StudioActivationSelection(
            question: question, maxTokens: tokenLimit, model: id, runtimeGeneration: runtimeGeneration,
            layers: Array(layers.map(\.index).sorted().prefix(layerLimit)), sites: sites,
            tokenPositions: .init(prefill: [-1], decode: Array(0..<tokenLimit)),
            capture: "summary", maxCaptureBytes: budget)
    }
}

struct StudioActivationSelection: Encodable, Sendable {
    struct Positions: Encodable, Sendable {
        let prefill: [Int]
        let decode: [Int]
    }
    let question: String
    let maxTokens: Int
    let model: String
    let runtimeGeneration: UInt64
    let layers: [Int]
    let sites: [String]
    let tokenPositions: Positions
    let capture: String
    let maxCaptureBytes: Int
}

struct StudioActivationTrace: Decodable {
    let model: String
    let question: String
    let answer: String
    let promptTokenCount: Int
    let generatedTokenCount: Int
    let tokens: [StudioActivationCapture.Token]
    let layers: [StudioActivationCapture.Layer]
    let stopReason: String
    let maxTokens: Int
    var components: [StudioActivationCapture.Layer]? = nil
    var expertRouting: [StudioActivationCapture.Routing]? = nil

    func validateComponents(selected: Set<Int>, positions: [Int]) throws {
        let components = components ?? []
        let routes = expertRouting ?? []
        guard components.count <= selected.count * 3, routes.count <= selected.count,
            Set(components.map { "\($0.index):\($0.site)" }).count == components.count,
            Set(routes.map(\.index)).count == routes.count
        else {
            throw ConfigurationError("Duplicate or excessive component observations.")
        }
        for component in components {
            guard selected.contains(component.index),
                ["attention_output", "feed_forward_output", "shared_expert_output"].contains(component.site),
                component.samples.map(\.tokenIndex) == positions,
                component.samples.allSatisfy({ $0.rms.isFinite && $0.rms >= 0 })
            else {
                throw ConfigurationError("Invalid component observation coverage or values.")
            }
        }
        for route in routes {
            guard selected.contains(route.index), (1...4096).contains(route.expertCount),
                route.samples.map(\.tokenIndex) == positions
            else {
                throw ConfigurationError("Invalid expert routing coverage.")
            }
            for sample in route.samples {
                guard (1...64).contains(sample.expertIDs.count), sample.weights.count == sample.expertIDs.count,
                    Set(sample.expertIDs).count == sample.expertIDs.count,
                    sample.expertIDs.allSatisfy({ $0 >= 0 && $0 < route.expertCount }),
                    sample.weights.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                    abs(sample.weights.reduce(0, +) - 1) < 0.02
                else {
                    throw ConfigurationError("Invalid expert IDs or normalized routing weights.")
                }
            }
        }
    }

    func validate(selection: StudioActivationSelection, descriptor: StudioActivationDescriptor) throws {
        guard model == selection.model, question == selection.question, maxTokens == selection.maxTokens,
            (1...256).contains(promptTokenCount), (0...selection.maxTokens).contains(generatedTokenCount),
            promptTokenCount <= (descriptor.traceCapabilities?.maxPrefillTokens ?? 0),
            promptTokenCount + generatedTokenCount == tokens.count, tokens.count <= 320,
            tokens.enumerated().allSatisfy({ index, token in
                token.position == index && token.id >= 0
                    && token.phase == (index < promptTokenCount ? "prompt" : "answer")
            })
        else {
            throw ConfigurationError("Midnight returned invalid recording tokens or a different model. Record again.")
        }
        let expectedSites = Set(selection.layers.flatMap { index in selection.sites.map { "\(index):\($0)" } })
        let receivedSites = layers.map { "\($0.index):\($0.site)" }
        guard Set(receivedSites) == expectedSites, receivedSites.count == expectedSites.count else {
            throw ConfigurationError("Midnight returned a different or incomplete layer/site selection. Record again.")
        }
        let expectedPositions = Set((promptTokenCount - 1)..<tokens.count)
        for layer in layers {
            let positions = layer.samples.map(\.tokenIndex)
            guard Set(positions) == expectedPositions, positions.count == expectedPositions.count,
                layer.samples.allSatisfy({ $0.rms.isFinite && $0.rms >= 0 })
            else {
                throw ConfigurationError("Midnight returned invalid or incomplete activation samples. Record again.")
            }
        }
    }
}

private struct StudioActivationErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
