import Foundation
import Testing

@testable import MidnightInspector

struct StudioRecordingTests {
    @Test func armObservesExternalChatAndNeverSubmitsPrompt() async throws {
        let fixture = RecordingFixture()
        let client = StudioRecordingClient { try await fixture.respond($0) }
        let armed = try await client.arm { await fixture.routing() }
        let pending = try await client.poll(armed) { await fixture.routing() }
        #expect(pending.status == "recording" && pending.capture == nil)
        let finished = try await client.poll(armed) { await fixture.routing() }
        let capture = try #require(finished.capture)
        #expect(capture.recordingID == RecordingFixture.id)
        #expect(capture.playableTokenIndices == Array(999...1031))
        #expect(capture.promptTokenCount == 1000)
        #expect(capture.cachedPromptTokenCount == 990)
        #expect(capture.tokens.count == 33)
        #expect(capture.question.isEmpty)
        let requests = await fixture.requests
        #expect(
            requests.map { $0.url!.path } == [
                "/v1/inspector/model", "/v1/inspector/recordings",
                "/v1/inspector/recordings/\(RecordingFixture.id)", "/v1/inspector/recordings/\(RecordingFixture.id)",
            ])
        let body = try #require(requests[1].httpBody)
        let selection = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(selection["question"] == nil && selection["messages"] == nil)
        #expect(selection["runtimeGeneration"] as? Int == 7)
        #expect(selection["maxTokens"] as? Int == 32)
    }

    @Test func cancellationTargetsRecordingAndOriginalConnectionOnly() async throws {
        let fixture = RecordingFixture()
        let client = StudioRecordingClient { try await fixture.respond($0) }
        let recording = try await client.arm { await fixture.routing() }
        await fixture.changeConnection()
        await #expect(throws: ConfigurationError.self) { try await client.poll(recording) { await fixture.routing() } }
        try await client.cancel(recording)
        let last = try #require(await fixture.requests.last)
        #expect(last.httpMethod == "DELETE")
        #expect(last.url?.host == "127.0.0.1")
        #expect(last.url?.path == "/v1/inspector/recordings/\(RecordingFixture.id)")
    }

    @Test(arguments: ["duplicate", "unknownSample", "negativeRMS", "otherModel", "unknownSite"])
    func malformedSavedOrNetworkCaptureIsRejected(_ mutation: String) throws {
        var trace = RecordingFixture.trace()
        if mutation == "otherModel" { trace["model"] = "different" }
        if mutation == "duplicate" {
            var tokens = trace["tokens"] as! [[String: Any]]
            tokens[1]["position"] = 999
            trace["tokens"] = tokens
        }
        if ["unknownSample", "negativeRMS", "unknownSite"].contains(mutation) {
            var layers = trace["layers"] as! [[String: Any]]
            if mutation == "unknownSite" { layers[0]["site"] = "invented" }
            var samples = layers[0]["samples"] as! [[String: Any]]
            if mutation == "unknownSample" { samples[0]["tokenIndex"] = 8 }
            if mutation == "negativeRMS" { samples[0]["rms"] = -1.0 }
            layers[0]["samples"] = samples
            trace["layers"] = layers
        }
        #expect(throws: ConfigurationError.self) {
            try StudioRecordingClient.decodeCapture(
                topology: JSONSerialization.data(withJSONObject: RecordingFixture.model()),
                trace: JSONSerialization.data(withJSONObject: trace), id: RecordingFixture.id,
                createdAt: 1, cachedPromptTokenCount: 990, expectedModel: "fixture", layers: [0, 1],
                sites: ["layer_input", "after_attention"])
        }
    }

    @Test func savesPrivateCaptureAndHistoryThenReopensWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StudioRecordingStore(stateDirectory: directory)
        let capture = try StudioRecordingClient.decodeCapture(
            topology: JSONSerialization.data(withJSONObject: RecordingFixture.model()),
            trace: JSONSerialization.data(withJSONObject: RecordingFixture.trace()), id: RecordingFixture.id,
            createdAt: 1, cachedPromptTokenCount: 990, expectedModel: "fixture", layers: [0, 1],
            sites: ["layer_input", "after_attention"])
        let file = try await store.save(capture)
        let entries = try await store.entries()
        #expect(entries.count == 1)
        let loaded = try await store.load(try #require(entries.first))
        #expect(loaded.recordingID == capture.recordingID)
        #expect(loaded.playableTokenIndices == capture.playableTokenIndices)
        #expect(loaded.answer == capture.answer && loaded.layers.count == capture.layers.count)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let history = try String(contentsOf: directory.appendingPathComponent("recordings.jsonl"), encoding: .utf8)
        #expect(history.contains("completed") && history.contains("recordings/"))
        #expect(!history.contains("Authorization") && !history.contains("Hello"))
        try Data("{}".utf8).write(to: file)
        await #expect(throws: ConfigurationError.self) { try await store.load(try #require(entries.first)) }
    }

    @Test func componentAndRoutingMeasurementsSurviveSavedReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StudioRecordingStore(stateDirectory: directory)
        let trace = componentTrace()
        let capture = try decodeComponents(trace)
        let file = try await store.save(capture)
        let entry = try #require(await store.entries().first)
        let loaded = try await store.load(entry)
        #expect(loaded.components?.first?.site == "attention_output")
        #expect(loaded.components?.first?.samples.first?.rms == 0)
        #expect(loaded.expertRouting?.first?.samples.first?.expertIDs == [1, 3])
        #expect(loaded.expertRouting?.first?.samples.first?.weights == [0.75, 0.25])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["missingPosition", "unknownComponent", "invalidID", "duplicateID", "invalidWeight"])
    func malformedComponentMeasurementsAreRejected(_ mutation: String) throws {
        var trace = componentTrace()
        var components = trace["components"] as! [[String: Any]]
        var routes = trace["expertRouting"] as! [[String: Any]]
        if mutation == "unknownComponent" { components[0]["site"] = "guess" }
        if mutation == "missingPosition" { components[0]["samples"] = [] }
        var samples = routes[0]["samples"] as! [[String: Any]]
        if mutation == "invalidID" { samples[0]["expertIDs"] = [1, 4] }
        if mutation == "duplicateID" { samples[0]["expertIDs"] = [1, 1] }
        if mutation == "invalidWeight" { samples[0]["weights"] = [0.7, 0.7] }
        routes[0]["samples"] = samples
        trace["components"] = components
        trace["expertRouting"] = routes
        #expect(throws: ConfigurationError.self) { try decodeComponents(trace) }
    }

    private func componentTrace() -> [String: Any] {
        var trace = RecordingFixture.trace()
        trace["components"] = [
            [
                "index": 0, "site": "attention_output",
                "samples": (999...1031).map { ["tokenIndex": $0, "rms": 0.0] as [String: Any] },
            ]
        ]
        trace["expertRouting"] = [
            [
                "index": 1, "path": "model.layers.1.mlp.router", "expertCount": 4,
                "samples": (999...1031).map {
                    ["tokenIndex": $0, "expertIDs": [1, 3], "weights": [0.75, 0.25]] as [String: Any]
                },
            ]
        ]
        return trace
    }

    private func decodeComponents(_ trace: [String: Any]) throws -> StudioActivationCapture {
        try StudioRecordingClient.decodeCapture(
            topology: JSONSerialization.data(withJSONObject: RecordingFixture.model()),
            trace: JSONSerialization.data(withJSONObject: trace), id: RecordingFixture.id, createdAt: 1,
            cachedPromptTokenCount: 990, expectedModel: "fixture", layers: [0, 1],
            sites: ["layer_input", "after_attention"])
    }

    @Test func managedRuntimeRequestsUseTheSameBearerCredential() async throws {
        let client = ModelControlRuntimeClient(apiKey: "fixture-secret") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            return UpstreamResponse(
                status: 200,
                body: Data(#"{"instanceID":"owned","processID":4242,"phase":"empty","modelGeneration":0}"#.utf8))
        }
        _ = try await client.state(at: URL(string: "http://127.0.0.1:8082")!, instanceID: "owned", processID: 4242)
    }

    @Test func bearerCredentialsAreAppliedWithoutOverwritingExplicitAuthorization() throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/inspector/model")!)
        #expect(
            InspectorHTTPClient.authorized(request, apiKey: "fixture-secret").value(forHTTPHeaderField: "Authorization")
                == "Bearer fixture-secret")
        request.setValue("Bearer explicit", forHTTPHeaderField: "Authorization")
        #expect(
            InspectorHTTPClient.authorized(request, apiKey: "fixture-secret").value(forHTTPHeaderField: "Authorization")
                == "Bearer explicit")
    }
}

private actor RecordingFixture {
    static let id = "8A0402DF-3C65-4F1C-9D59-C962259633DD"
    private var revision = "first"
    private var polls = 0
    private(set) var requests: [URLRequest] = []

    func routing() -> ModelControlRoutingState {
        ModelControlRoutingState(
            revision: revision, mode: "external", phase: "idle", url: URL(string: "http://127.0.0.1:8080")!)
    }
    func changeConnection() { revision = "second" }

    func respond(_ request: URLRequest) throws -> UpstreamResponse {
        requests.append(request)
        var object: [String: Any]
        if request.url?.path == "/v1/inspector/model" {
            object = Self.model()
        } else {
            var status = "armed"
            if request.httpMethod == "DELETE" {
                status = "cancelled"
            } else if request.httpMethod != "POST" {
                polls += 1
                status = polls == 1 ? "recording" : "completed"
            }
            object = [
                "id": Self.id, "createdAt": 1.0, "status": status, "model": Self.model(), "cachedPromptTokenCount": 990,
            ]
            if status == "completed" { object["trace"] = Self.trace() }
        }
        return UpstreamResponse(
            status: request.httpMethod == "POST" ? 202 : 200, body: try JSONSerialization.data(withJSONObject: object))
    }

    nonisolated static func model() -> [String: Any] {
        [
            "id": "fixture", "traceSupported": true, "runtimeGeneration": 7, "layerCount": 2,
            "layers": [["index": 0], ["index": 1]],
            "traceCapabilities": [
                "version": 1, "captureModes": ["summary"], "maxSelectedLayers": 128,
                "maxPrefillTokens": 256, "maxDecodeTokens": 64, "maxCaptureBytes": 16 * 1024 * 1024,
                "observationPoints": [
                    ["site": "layer_input", "hiddenSize": 256], ["site": "after_attention", "hiddenSize": 256],
                ],
            ],
        ]
    }

    nonisolated static func trace() -> [String: Any] {
        [
            "model": "fixture", "question": "", "answer": "Hello there", "maxTokens": 32,
            "promptTokenCount": 1000, "generatedTokenCount": 150, "stopReason": "stop",
            "tokens": (999...1031).map { position in
                [
                    "id": position, "position": position, "text": position == 999 ? "?" : "Hello",
                    "phase": position == 999 ? "prompt" : "answer",
                ] as [String: Any]
            },
            "layers": [0, 1].flatMap { index in
                ["layer_input", "after_attention"].map { site in
                    [
                        "index": index, "site": site,
                        "samples": (999...1031).map { ["tokenIndex": $0, "rms": 0.8] as [String: Any] },
                    ] as [String: Any]
                }
            },
        ]
    }
}
