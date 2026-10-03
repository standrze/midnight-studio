import Foundation
import Testing

@testable import MidnightInspector

struct StudioActivationCaptureTests {
    @Test func recordsExplicitBoundedSelectionsAndMeasuredPlayback() async throws {
        let fixture = ActivationFixture()
        let capture = try await record(fixture, question: "  Name a moon.  ")
        let requests = await fixture.requests
        let request = try #require(requests.last)
        let body = try #require(request.httpBody)
        let selection = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request.url?.path == "/v1/inspector/trace")
        #expect(request.httpMethod == "POST")
        #expect(selection["question"] as? String == "Name a moon.")
        #expect(selection["model"] as? String == "fixture")
        #expect(selection["runtimeGeneration"] as? Int == 7)
        #expect(selection["maxTokens"] as? Int == 8)
        #expect(selection["capture"] as? String == "summary")
        #expect(selection["layers"] as? [Int] == [0, 1, 2])
        #expect(selection["sites"] as? [String] == ["layer_input", "after_attention"])
        let positions = try #require(selection["tokenPositions"] as? [String: [Int]])
        #expect(positions["prefill"] == [-1])
        #expect(positions["decode"] == Array(0..<8))
        #expect(capture.playableTokenIndices == [1, 2])
        #expect(capture.tokens[2].phase == "answer")
        #expect(capture.rms(layerIndex: 2, site: "layer_input", tokenIndex: 2) == 3)
        #expect(capture.rms(layerIndex: 2, site: "layer_input", tokenIndex: 0) == nil)
        #expect(capture.maxRMS(site: "after_attention") == 3)
        #expect(capture.selectionNote == "Captured all 3 layers.")
        #expect(!capture.topologyData.isEmpty && !capture.captureData.isEmpty)
    }

    @Test func limitsLayersAndDecodeToAdvertisedCapabilities() async throws {
        let fixture = ActivationFixture(maxSelectedLayers: 2, maxDecodeTokens: 3, sites: ["after_attention"])
        let capture = try await record(fixture)
        #expect(capture.capturedLayerIndices == [0, 1])
        #expect(capture.capturedSites == ["after_attention"])
        #expect(capture.maxTokens == 3)
        #expect(capture.selectionNote.contains("first 2 of 3"))
    }

    @Test func captureByteBudgetCanReduceLayerSelection() async throws {
        // Nine selected positions need 12,128 encoded bytes per layer with both sites.
        let fixture = ActivationFixture(maxCaptureBytes: 13_000)
        let capture = try await record(fixture)
        #expect(capture.capturedLayerIndices == [0])
        #expect(capture.selectionNote.contains("first 1 of 3"))
    }

    @Test func unsupportedModelsDoNotStartGeneration() async throws {
        let fixture = ActivationFixture(traceSupported: false)
        await #expect(throws: ConfigurationError.self) { try await record(fixture) }
        let requests = await fixture.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
    }

    @Test func staleRoutingIsRejectedBeforeAnyRequest() async throws {
        let fixture = ActivationFixture()
        await fixture.changeRevision()
        await #expect(throws: ConfigurationError.self) { try await record(fixture) }
        #expect(await fixture.requests.isEmpty)
    }

    @Test(arguments: [ActivationFixture.Mutation.changeAfterModel, .changeAfterTrace])
    private func changedRoutingCannotProduceCapture(_ mutation: ActivationFixture.Mutation) async throws {
        let fixture = ActivationFixture(mutation: mutation)
        await #expect(throws: ConfigurationError.self) { try await record(fixture) }
        #expect(await fixture.requests.count == (mutation == .changeAfterModel ? 1 : 2))
    }

    @Test(arguments: [ActivationFixture.Mutation.duplicateToken, .duplicateSample, .missingSite, .negativeRMS])
    private func invalidMeasurementsCannotProducePlayback(_ mutation: ActivationFixture.Mutation) async throws {
        let fixture = ActivationFixture(mutation: mutation)
        await #expect(throws: ConfigurationError.self) { try await record(fixture) }
    }

    @Test func cancelledTransportDoesNotProduceCapture() async throws {
        let fixture = ActivationFixture(mutation: .cancel)
        let task = Task { try await record(fixture) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func serverValidationMessageIsPreserved() async throws {
        let fixture = ActivationFixture(mutation: .serverError)
        do {
            _ = try await record(fixture)
            Issue.record("An HTTP error must reject the capture.")
        } catch {
            #expect(String(describing: error).contains("Shorten the question."))
        }
    }

    private func record(_ fixture: ActivationFixture, question: String = "Name a moon.") async throws
        -> StudioActivationCapture
    {
        let client = StudioActivationCaptureClient { try await fixture.respond(to: $0) }
        return try await client.record(question: question, expectedRevision: "first") { await fixture.routing() }
    }
}

private actor ActivationFixture {
    enum Mutation: Sendable {
        case none, changeAfterModel, changeAfterTrace, duplicateToken, duplicateSample, missingSite, negativeRMS
        case cancel, serverError
    }

    private let maxSelectedLayers: Int
    private let maxDecodeTokens: Int
    private let maxCaptureBytes: Int
    private let sites: [String]
    private let traceSupported: Bool
    private let mutation: Mutation
    private var revision = "first"
    private(set) var requests: [URLRequest] = []

    init(
        maxSelectedLayers: Int = 3, maxDecodeTokens: Int = 64, maxCaptureBytes: Int = 16 * 1024 * 1024,
        sites: [String] = ["layer_input", "after_attention"], traceSupported: Bool = true, mutation: Mutation = .none
    ) {
        self.maxSelectedLayers = maxSelectedLayers
        self.maxDecodeTokens = maxDecodeTokens
        self.maxCaptureBytes = maxCaptureBytes
        self.sites = sites
        self.traceSupported = traceSupported
        self.mutation = mutation
    }

    func changeRevision() { revision = "second" }

    func routing() -> ModelControlRoutingState {
        ModelControlRoutingState(
            revision: revision, mode: "external", phase: "idle", url: URL(string: "http://127.0.0.1:8080")!)
    }

    func respond(to request: URLRequest) throws -> UpstreamResponse {
        requests.append(request)
        if mutation == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
        if request.httpMethod == "GET" {
            if mutation == .changeAfterModel { changeRevision() }
            return try response([
                "id": "fixture", "traceSupported": traceSupported, "runtimeGeneration": 7, "layerCount": 3,
                "layers": (0..<3).map { ["index": $0] },
                "traceCapabilities": [
                    "version": 1, "captureModes": ["summary"], "maxSelectedLayers": maxSelectedLayers,
                    "maxPrefillTokens": 256, "maxDecodeTokens": maxDecodeTokens, "maxCaptureBytes": maxCaptureBytes,
                    "observationPoints": sites.map { ["site": $0, "hiddenSize": 256] as [String: Any] },
                ],
            ])
        }
        if mutation == .changeAfterTrace { changeRevision() }
        if mutation == .serverError {
            return try response(["error": ["message": "Shorten the question."]], status: 400)
        }
        let body = try #require(request.httpBody)
        let selection = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let selectedLayers = try #require(selection["layers"] as? [Int])
        let selectedSites = try #require(selection["sites"] as? [String])
        var tokens: [[String: Any]] = [
            ["id": 10, "position": 0, "text": "Name", "phase": "prompt"],
            ["id": 11, "position": 1, "text": " a moon.", "phase": "prompt"],
            ["id": 12, "position": 2, "text": "Titan", "phase": "answer"],
        ]
        if mutation == .duplicateToken { tokens[2]["position"] = 1 }
        var layers: [[String: Any]] = selectedLayers.flatMap { index in
            selectedSites.map { site in
                var samples: [[String: Any]] = [
                    ["tokenIndex": 1, "rms": Double(index + 1)],
                    ["tokenIndex": 2, "rms": Double(index + 1)],
                ]
                if mutation == .duplicateSample { samples[1]["tokenIndex"] = 1 }
                if mutation == .negativeRMS { samples[1]["rms"] = -1.0 }
                return ["index": index, "site": site, "samples": samples]
            }
        }
        if mutation == .missingSite { layers.removeLast() }
        return try response([
            "model": "fixture", "question": selection["question"]!, "answer": "Titan",
            "promptTokenCount": 2, "generatedTokenCount": 1, "tokens": tokens, "layers": layers,
            "stopReason": "stop", "maxTokens": selection["maxTokens"]!,
        ])
    }

    private func response(_ object: [String: Any], status: Int = 200) throws -> UpstreamResponse {
        UpstreamResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
    }
}
