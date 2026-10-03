import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import MidnightInspector

struct ModelControlServerTests {
    @Test func launchConfigurationAcceptsOnlyFixedCLIPathsAndDistinctPorts() throws {
        let configuration = try InspectorConfiguration(arguments: [
            "--midnight-binary", "/tmp/custom-midnight", "--model-root", "/tmp/models-one",
            "--model-root", "/tmp/models-two", "--state-directory", "/tmp/inspector-profiles",
            "--managed-port", "8182",
        ])
        #expect(configuration.midnightBinary.path == "/tmp/custom-midnight")
        #expect(configuration.modelRoots.map(\.path) == ["/tmp/models-one", "/tmp/models-two"])
        #expect(configuration.stateDirectory.path == "/tmp/inspector-profiles")
        #expect(configuration.managedPort == 8182)
        for arguments in [
            ["--managed-port", "0"], ["--managed-port", "65536"],
            ["--managed-port", "8090"], ["--managed-port", "8080"],
            ["--compare-url", "http://127.0.0.1:8082"],
            ["--model-root"], ["--midnight-binary"], ["--state-directory", ""],
        ] {
            #expect(throws: ConfigurationError.self) { try InspectorConfiguration(arguments: arguments) }
        }
    }

    @Test func catalogAndSavedProfilePreserveExternalInspectorConnection() async throws {
        let fixture = try ControlServerFixture()
        defer { fixture.remove() }
        let manager = ModelControlManager(configuration: fixture.configuration)
        let model = try #require(await manager.catalog().first)
        var profile = model.defaults
        profile.contextLength = 8192
        profile.maximumTokens = 256
        let savedProfile = profile
        let profileData = try JSONEncoder().encode(savedProfile)
        let server = InspectorServer(configuration: try .init(), modelControl: manager)
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(uri: "/api/control/models", method: .get) { response in
                #expect(response.status == .ok)
                let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                let models = try #require(object["models"] as? [[String: Any]])
                #expect(models.count == 1)
                #expect(models.first?["id"] as? String == model.id)
            }
            try await client.execute(
                uri: "/api/control/profile", method: .post,
                headers: [.contentType: "application/json", .origin: "http://127.0.0.1:8090"],
                body: .init(bytes: profileData)
            ) { response in
                #expect(response.status == .ok)
                let state = try JSONDecoder().decode(ModelControlState.self, from: Data(response.body.readableBytesView))
                #expect(state.mode == "external")
                #expect(state.savedProfiles.contains(savedProfile))
                #expect(state.activeProfile == nil)
            }
            try await client.execute(uri: "/api/connections", method: .get) { response in
                #expect(String(buffer: response.body).contains("http:\\/\\/127.0.0.1:8080") || String(buffer: response.body).contains("http://127.0.0.1:8080"))
                #expect(!String(buffer: response.body).contains("8082"))
            }
        }
        let restored = ModelControlManager(configuration: fixture.configuration)
        #expect(await restored.state().savedProfiles.contains(savedProfile))
    }

    @Test func invalidControlRequestsCannotMutateProfilesOrLaunchProcesses() async throws {
        let fixture = try ControlServerFixture()
        defer { fixture.remove() }
        let manager = ModelControlManager(configuration: fixture.configuration)
        let model = try #require(await manager.catalog().first)
        let profileData = try JSONEncoder().encode(model.defaults)
        let server = InspectorServer(configuration: try .init(), modelControl: manager)
        try await Application(router: server.router()).test(.router) { client in
            for path in ["/api/control/profile", "/api/control/load", "/api/control/unload", "/api/control/external"] {
                try await client.execute(
                    uri: path, method: .post,
                    headers: [.contentType: "application/json", .origin: "https://foreign.example"],
                    body: .init(bytes: profileData)
                ) { response in #expect(response.status == .forbidden) }
                try await client.execute(
                    uri: path, method: .post, headers: [.contentType: "text/plain"], body: .init(string: "{}")
                ) { response in #expect(response.status == .unsupportedMediaType) }
            }
            try await client.execute(
                uri: "/api/control/profile", method: .post, headers: [.contentType: "application/json"],
                body: .init(string: String(repeating: "x", count: InspectorServer.maximumRequestBytes + 1))
            ) { response in #expect(response.status == .contentTooLarge) }
            for body in ["null", "[]", "{", #"{"executable":"/tmp/anything","arguments":["unsafe"]}"#] {
                try await client.execute(
                    uri: "/api/control/load", method: .post, headers: [.contentType: "application/json"],
                    body: .init(string: body)
                ) { response in #expect(response.status == .badRequest) }
            }
            for body in ["[]", #"{"endpoint":"http://other.example"}"#] {
                try await client.execute(
                    uri: "/api/control/external", method: .post, headers: [.contentType: "application/json"],
                    body: .init(string: body)
                ) { response in #expect(response.status == .badRequest) }
            }
        }
        let state = await manager.state()
        #expect(state.mode == "external")
        #expect(state.savedProfiles.isEmpty)
        #expect(state.processID == nil)
    }

    @Test func validatesProfileAndUnavailableExecutableWithoutChangingActiveConnection() async throws {
        let fixture = try ControlServerFixture()
        defer { fixture.remove() }
        let manager = ModelControlManager(configuration: fixture.configuration)
        let model = try #require(await manager.catalog().first)
        let server = InspectorServer(configuration: try .init(), modelControl: manager)
        try await Application(router: server.router()).test(.router) { client in
            var invalid = model.defaults
            invalid.contextLength = 131073
            try await client.execute(
                uri: "/api/control/profile", method: .post, headers: [.contentType: "application/json"],
                body: .init(bytes: try JSONEncoder().encode(invalid))
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("invalid_profile"))
            }
            try await client.execute(
                uri: "/api/control/load", method: .post, headers: [.contentType: "application/json"],
                body: .init(bytes: try JSONEncoder().encode(model.defaults))
            ) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(String(buffer: response.body).contains("launch_unavailable"))
            }
            try await client.execute(
                uri: "/api/control/unload", method: .post, headers: [.contentType: "application/json"],
                body: .init(string: "{}")
            ) { response in #expect(response.status == .ok) }
        }
        #expect(await manager.state().mode == "external")
        #expect(await manager.activeManagedURL() == nil)
    }

    @Test func managedLoadingChangesOnlyPrimaryAndExplicitExternalRestoresIt() async throws {
        let fixture = try ControlServerFixture(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        defer { fixture.remove() }
        let child = ControlServerChild()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }), portCheck: { _ in }
        )
        let model = try #require(await manager.catalog().first)
        let configuration = try InspectorConfiguration(arguments: ["--compare-url", "http://127.0.0.1:8081"])
        let server = InspectorServer(configuration: configuration, modelControl: manager) { request in
            #expect([8080, 8081, 8182].contains(request.url?.port ?? 0))
            return UpstreamResponse(status: 200, body: Data("{\"port\":\(request.url!.port!)}".utf8))
        }
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(
                uri: "/api/control/load", method: .post, headers: [.contentType: "application/json"],
                body: .init(bytes: try JSONEncoder().encode(model.defaults))
            ) { response in #expect(response.status == .ok) }
            try await waitForControlPhase(manager, "loaded")
            try await client.execute(uri: "/api/model", method: .get) { response in
                #expect(String(buffer: response.body) == #"{"port":8182}"#)
            }
            try await client.execute(uri: "/api/model?connection=comparison", method: .get) { response in
                #expect(String(buffer: response.body) == #"{"port":8081}"#)
            }
            try await client.execute(
                uri: "/api/control/external", method: .post, headers: [.contentType: "application/json"],
                body: .init(string: "{}")
            ) { response in #expect(response.status == .ok) }
            try await client.execute(uri: "/api/model", method: .get) { response in
                #expect(String(buffer: response.body) == #"{"port":8080}"#)
            }
        }
        await manager.shutdown()
        #expect(await manager.activeManagedURL() == nil)
    }

    @Test func managedRequestsWaitForReadinessWhileComparisonStaysAvailable() async throws {
        let fixture = try ControlServerFixture(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        defer { fixture.remove() }
        let child = ControlServerChild()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in false }), portCheck: { _ in }
        )
        let model = try #require(await manager.catalog().first)
        _ = try await manager.load(model.defaults)
        let server = InspectorServer(
            configuration: try .init(arguments: ["--compare-url", "http://127.0.0.1:8081"]), modelControl: manager
        ) { request in
            #expect(request.url?.port == 8081, "Managed requests must not reach a model before readiness is confirmed")
            return UpstreamResponse(status: 200, body: Data("{}".utf8))
        }
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(uri: "/api/model", method: .get) { response in
                #expect(response.status == .conflict)
                #expect(String(buffer: response.body).contains("model_not_ready"))
            }
            try await client.execute(
                uri: "/api/trace", method: .post, headers: [.contentType: "application/json"],
                body: .init(string: #"{"question":"Hello"}"#)
            ) { response in
                #expect(response.status == .conflict)
                #expect(String(buffer: response.body).contains("model_not_ready"))
            }
            try await client.execute(uri: "/api/model?connection=comparison", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
        await manager.shutdown()
    }

    @Test func discardsInflightPrimaryResponsesAfterEitherConnectionSwitch() async throws {
        for startsManaged in [false, true] {
            let fixture = try ControlServerFixture(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
            defer { fixture.remove() }
            let child = ControlServerChild()
            let manager = ModelControlManager(
                configuration: fixture.configuration,
                launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }), portCheck: { _ in }
            )
            let model = try #require(await manager.catalog().first)
            if startsManaged {
                _ = try await manager.load(model.defaults)
                try await waitForControlPhase(manager, "loaded")
            }
            let gate = ControlServerResponseGate()
            let server = InspectorServer(configuration: try .init(), modelControl: manager) { request in
                #expect(request.url?.port == (startsManaged ? 8182 : 8080))
                return await gate.response()
            }
            try await Application(router: server.router()).test(.router) { client in
                async let pending: Void = client.execute(uri: "/api/model", method: .get) { response in
                    #expect(response.status == .conflict)
                    #expect(String(buffer: response.body).contains("model_changed"))
                    #expect(!String(buffer: response.body).contains("stale-model"))
                }
                try await gate.waitUntilStarted()
                if startsManaged {
                    try await client.execute(
                        uri: "/api/control/external", method: .post, headers: [.contentType: "application/json"],
                        body: .init(string: "{}")
                    ) { response in #expect(response.status == .ok) }
                } else {
                    try await client.execute(
                        uri: "/api/control/load", method: .post, headers: [.contentType: "application/json"],
                        body: .init(bytes: try JSONEncoder().encode(model.defaults))
                    ) { response in #expect(response.status == .ok) }
                }
                await gate.release()
                try await pending
            }
            await manager.shutdown()
        }
    }
}

private func waitForControlPhase(_ manager: ModelControlManager, _ phase: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await manager.state().phase != phase {
        guard ContinuousClock.now < deadline else {
            throw ConfigurationError("Timed out waiting for managed test phase \(phase).")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct ControlServerFixture {
    let root: URL
    let configuration: ModelControlConfiguration

    init(executableURL: URL? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("midnight-control-http-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let model = models.appendingPathComponent("gpt-oss-test", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss","num_hidden_layers":24,"max_position_embeddings":131072}"#.utf8)
            .write(to: model.appendingPathComponent("config.json"))
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        configuration = ModelControlConfiguration(
            executableURL: executableURL ?? root.appendingPathComponent("missing-midnight"), modelRoots: [models],
            stateDirectory: root.appendingPathComponent("state"), managedPort: 8182
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ControlServerChild: ModelControlChild, @unchecked Sendable {
    let processIdentifier: Int32 = 4242
    private let lock = NSLock()
    private var current: ModelControlChildStatus = .running
    func status() -> ModelControlChildStatus { lock.withLock { current } }
    func terminate() { lock.withLock { current = .exited(0) } }
    func forceTerminate() { terminate() }
    func drainLogs() -> [String] { [] }
}

private actor ControlServerResponseGate {
    private var started = false
    private var released = false
    private var responseWaiter: CheckedContinuation<Void, Never>?

    func response() async -> UpstreamResponse {
        started = true
        if !released { await withCheckedContinuation { responseWaiter = $0 } }
        return UpstreamResponse(status: 200, body: Data(#"{"name":"stale-model","layers":[]}"#.utf8))
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !started {
            guard ContinuousClock.now < deadline else { throw ConfigurationError("The test proxy request did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        released = true
        responseWaiter?.resume()
        responseWaiter = nil
    }
}
