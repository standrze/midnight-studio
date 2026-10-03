import Foundation
import Testing

@testable import MidnightInspector

struct StudioInspectionClientTests {
    @Test func stableConnectionProducesTopology() async throws {
        let route = RouteFixture()
        let client = StudioInspectionClient { request in
            #expect(request.url?.path == "/v1/inspector/model")
            return UpstreamResponse(status: 200, body: Data(#"{"model":"fixture"}"#.utf8))
        }
        let lines = try await client.read(path: "v1/inspector/model") { await route.current() }
        #expect(lines.map(\.text).joined().contains("fixture"))
    }

    @Test func changedSelectionDiscardsInflightInspection() async throws {
        let route = RouteFixture()
        let client = StudioInspectionClient { _ in
            await route.change()
            return UpstreamResponse(status: 200, body: Data(#"{"model":"old-model"}"#.utf8))
        }
        await #expect(throws: ConfigurationError.self) {
            try await client.read(path: "v1/inspector/model") { await route.current() }
        }
    }

    @Test func cancelledInspectionDoesNotProduceAView() async throws {
        let route = RouteFixture()
        let client = StudioInspectionClient { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return UpstreamResponse(status: 200, body: Data(#"{"model":"fixture"}"#.utf8))
        }
        let task = Task {
            try await client.read(path: "v1/inspector/model") { await route.current() }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor RouteFixture {
    var revision = "first"
    func change() { revision = "second" }
    func current() -> ModelControlRoutingState {
        ModelControlRoutingState(
            revision: revision, mode: "external", phase: "idle", url: URL(string: "http://127.0.0.1:8080")!)
    }
}
