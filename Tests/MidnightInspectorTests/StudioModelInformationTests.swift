import Foundation
import Testing

@testable import MidnightInspector

struct StudioModelInformationTests {
    @Test func modelDetailsSeparateWeightStorageFromAllocatorUsageAndThroughput() async throws {
        let fixture = InformationFixture()
        let client = StudioInspectionClient { try await fixture.respond($0) }
        let snapshot = try await client.modelInformation { await fixture.route() }
        let text = snapshot.rows(width: 100).map(\.text).joined(separator: "\n")
        #expect(text.contains("ARCHITECTURE") && text.contains("MEMORY / VRAM"))
        #expect(text.contains("full_attention · sparse") && text.contains("4-bit affine"))
        #expect(text.contains("3.00 GiB") && text.contains("4.00 GiB") && text.contains("8.00 GiB"))
        #expect(text.contains("42.5 tok/s") && text.contains("1200.0 tok/s"))
        #expect(text.contains("Dedicated VRAM total is not reported"))
        #expect(text.contains("LATEST GENERATION"))
    }

    @Test func runtimeRefreshCachesArchitectureOnlyForTheSameResidentGeneration() async throws {
        let fixture = InformationFixture()
        let client = StudioInspectionClient { try await fixture.respond($0) }
        let first = try await client.modelInformation { await fixture.route() }
        _ = try await client.modelInformation(previous: first) { await fixture.route() }
        #expect(await fixture.paths == ["/v1/runtime", "/v1/inspector/model", "/v1/runtime"])
        await fixture.replace()
        let replaced = try await client.modelInformation(previous: first) { await fixture.route() }
        #expect(replaced.modelID == "model-2" && replaced.generation == 2)
        #expect(await fixture.paths.last == "/v1/inspector/model")
        #expect(
            replaced.rows(width: 100).first { $0.text.hasPrefix("Decode throughput") }?.text.contains("Not reported")
                == true)
    }

    @Test func missingRuntimeKeepsArchitectureAndDoesNotInventPerformance() async throws {
        let fixture = InformationFixture(runtimeUnavailable: true)
        let client = StudioInspectionClient { try await fixture.respond($0) }
        let snapshot = try await client.modelInformation { await fixture.route() }
        #expect(snapshot.modelID == "model-1" && snapshot.runtimeData == nil)
        #expect(!snapshot.notes.isEmpty)
        let rows = snapshot.rows(width: 80)
        #expect(rows.first { $0.text.hasPrefix("Active MLX memory") }?.text.contains("Not reported") == true)
        #expect(rows.first { $0.text.hasPrefix("Decode throughput") }?.text.contains("Not reported") == true)
    }

    @Test func mixedModelGenerationsAreRejected() async throws {
        let fixture = InformationFixture(mismatch: true)
        let client = StudioInspectionClient { try await fixture.respond($0) }
        await #expect(throws: ConfigurationError.self) {
            try await client.modelInformation { await fixture.route() }
        }
    }
}

private actor InformationFixture {
    var generation = 1
    let runtimeUnavailable: Bool
    let mismatch: Bool
    private(set) var paths: [String] = []

    init(runtimeUnavailable: Bool = false, mismatch: Bool = false) {
        self.runtimeUnavailable = runtimeUnavailable
        self.mismatch = mismatch
    }
    func replace() { generation = 2 }
    func route() -> ModelControlRoutingState {
        ModelControlRoutingState(
            revision: "stable", mode: "external", phase: "idle", url: URL(string: "http://127.0.0.1:8080")!)
    }
    func respond(_ request: URLRequest) throws -> UpstreamResponse {
        let path = request.url!.path
        paths.append(path)
        if path == "/v1/runtime", runtimeUnavailable { return .init(status: 404, body: Data()) }
        var object: [String: Any]
        if path == "/v1/runtime" {
            object = [
                "modelGeneration": generation, "phase": "ready",
                "memory": [
                    "activeBytes": 4 * 1_073_741_824, "cachedBytes": 1_073_741_824, "peakBytes": 5 * 1_073_741_824,
                ],
                "loadedModel": ["id": "model-\(generation)", "memory_limit_bytes": 8 * 1_073_741_824],
            ]
            if generation == 1 {
                object["generationMetrics"] = [
                    "tokensPerSecond": 42.5, "promptTokensPerSecond": 1200,
                    "promptTokenCount": 512, "prefilledPromptTokenCount": 384, "cachedPromptTokenCount": 128,
                    "generationTokenCount": 32, "stopReason": "stop",
                ]
            }
        } else {
            object = [
                "id": "model-\(generation)", "modelType": "laguna", "runtimeType": "LagunaModel",
                "runtimeGeneration": mismatch ? generation + 1 : generation, "layerCount": 1, "hiddenSize": 128,
                "attentionHeads": 4, "kvHeads": 2, "expertCount": 8, "expertsPerToken": 2,
                "weightBytes": 3 * 1_073_741_824, "traceSupported": true,
                "layers": [
                    [
                        "index": 0, "kind": "full_attention · sparse",
                        "modules": [
                            [
                                "quantization": [
                                    "bits": 4,
                                    "groupSize": 64, "format": "affine",
                                ], "parameters": [["dtype": "uint32"]],
                            ]
                        ],
                    ]
                ],
            ]
        }
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
