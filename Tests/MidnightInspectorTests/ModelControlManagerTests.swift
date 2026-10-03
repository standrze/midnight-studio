import Foundation
import Testing

@testable import MidnightInspector

struct ModelControlManagerTests {
    @Test func explicitPreflightRejectionPreservesTheReadyProfileAdapterAndError() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let runtime = FakeControlRuntime()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in process }, runtime: runtime, portCheck: { _ in })
        let original = try #require(await manager.catalog().first).defaults
        let adapter = URL(fileURLWithPath: "/tmp/original-adapter")
        _ = try await manager.load(original, adapter: adapter)
        try await waitFor(manager, phase: "loaded")
        var replacement = original
        replacement.servedModelName = "rejected-model"
        await runtime.rejectNextLoad(
            ModelControlError("The selected adapter is invalid.", code: "runtime_error", status: 400))
        _ = try await manager.load(replacement, adapter: URL(fileURLWithPath: "/tmp/invalid-adapter"))
        try await waitFor(manager, phase: "loaded")
        // Check another monitor cycle, which used to overwrite the original error.
        try await Task.sleep(for: .milliseconds(120))
        let state = await manager.state()
        #expect(state.activeProfile == original)
        #expect(state.adapterPath == adapter.path)
        #expect(state.lastError == "The selected adapter is invalid.")
        #expect(state.message.contains("remains loaded and ready"))
        #expect(state.operationID == nil)
        #expect(state.processID == process.processIdentifier)
        #expect(await manager.routingState().phase == "loaded")
        #expect(await manager.routingState().url == fixture.configuration.managedURL)
        #expect(process.terminations == 0)
        await manager.shutdown()
    }

    @Test func uncertainRuntimeFailureDoesNotRestoreThePreviousSelection() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let runtime = FakeControlRuntime()
        let process = FakeControlChild()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in process }, runtime: runtime, portCheck: { _ in })
        var profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        profile.servedModelName = "uncertain-model"
        await runtime.rejectNextLoad(
            ModelControlError("Runtime connection failed.", code: "runtime_error", status: 503))
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "error")
        #expect(await manager.routingState().phase == "error")
        #expect((await manager.state()).activeProfile == profile)
        await manager.shutdown()
    }

    @Test func replacementUnloadAndFailureRecoveryReuseOneRunner() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let launches = LaunchRecorder(child: process)
        let runtime = FakeControlRuntime()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { launches.launch($0) }, runtime: runtime, portCheck: { _ in })
        var profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        let originalRevision = await manager.routingState().revision
        profile.servedModelName = "second model"
        _ = try await manager.load(profile, adapter: URL(fileURLWithPath: "/tmp/adapter"))
        try await waitFor(manager, phase: "loaded")
        #expect(await manager.routingState().revision != originalRevision)
        #expect(await runtime.loadedRequests().last?.adapter == "/tmp/adapter")
        _ = try await manager.unload()
        try await waitFor(manager, phase: "idle")
        #expect((await manager.state()).activeProfile == nil)
        await runtime.failNextLoad("Test load failure")
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "error")
        #expect((await manager.state()).lastError == "Test load failure")
        await runtime.failNextLoad(nil)
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        #expect(launches.values.count == 1)
        #expect(process.terminations == 0)
        #expect((await manager.state()).processID == process.processIdentifier)
        await manager.shutdown()
        #expect(process.terminations == 1)
    }

    @Test func matchingModelFromADifferentOperationCannotCompleteALoad() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in process }, runtime: SupersededControlRuntime(), portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "error")
        try await Task.sleep(for: .milliseconds(120))
        #expect((await manager.state()).phase == "error")
        #expect(process.terminations == 0)
        await manager.shutdown()
    }

    @Test func catalogReadsMetadataAndValidatesLimitsWithoutChangingCheckpoint() throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let catalog = ModelControlCatalog(roots: [fixture.models])
        let model = try #require(catalog.models().first)
        #expect(model.layerCount == 24)
        #expect(model.architectureContextLength == 131072)
        #expect(model.weightBytes == 8)
        #expect(model.quantization == "4-bit mxfp4")
        #expect(model.supportsKVCompression == false)
        #expect(model.defaults.contextLength == 32768)
        var profile = model.defaults
        profile.contextLength = 131073
        #expect(throws: ModelControlError.self) { try catalog.validate(profile) }
        profile = model.defaults
        profile.maximumTokens = profile.contextLength
        #expect(throws: ModelControlError.self) { try catalog.validate(profile) }
        profile = model.defaults
        profile.kvCompression = "affine4"
        #expect(throws: ModelControlError.self) { try catalog.validate(profile) }
        profile = model.defaults
        profile.prefillStepSize = 8193
        #expect(throws: ModelControlError.self) { try catalog.validate(profile) }
        profile = model.defaults
        profile.engine = "cuda"
        #expect(throws: ModelControlError.self) { try catalog.validate(profile) }
        #expect(
            !FileManager.default.fileExists(atPath: fixture.checkpoint.appendingPathComponent("midnight.json").path))
    }

    @Test func catalogDoesNotFollowFoldersOrMetadataOutsideConfiguredRoots() throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.copyItem(at: fixture.checkpoint, to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.models.appendingPathComponent("escaped"), withDestinationURL: outside)
        let catalog = ModelControlCatalog(roots: [fixture.models])
        #expect(catalog.models().count == 1)
        try FileManager.default.removeItem(at: fixture.checkpoint.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            at: fixture.checkpoint.appendingPathComponent("config.json"),
            withDestinationURL: outside.appendingPathComponent("config.json"))
        #expect(catalog.models().isEmpty)
    }

    @Test func metadataAliasesIgnoreBooleansAndHonorCheckpointDefaults() throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        try Data(
            #"{"text_config":{"model_type":"mistral","n_layer":8,"max_position_embeddings":true,"seq_length":8192}}"#
                .utf8
        )
        .write(to: fixture.checkpoint.appendingPathComponent("config.json"))
        try Data(#"{"contextLength":4096,"maximumTokens":128,"prefillStepSize":256,"kvCompression":"affine8"}"#.utf8)
            .write(to: fixture.checkpoint.appendingPathComponent("midnight.json"))
        let model = try #require(ModelControlCatalog(roots: [fixture.models]).models().first)
        #expect(model.architectureContextLength == 8192)
        #expect(model.layerCount == 8)
        #expect(model.supportsKVCompression)
        #expect(model.defaults.contextLength == 4096)
        #expect(model.defaults.maximumTokens == 128)
        #expect(model.defaults.prefillStepSize == 256)
        #expect(model.defaults.kvCompression == "affine8")
    }

    @Test func loadIsAsynchronousAndUnloadRetainsTheManagedRunner() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let launches = LaunchRecorder(child: process)
        let gate = ReadinessGate()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { launches.launch($0) },
            runtime: FakeControlRuntime(readiness: { _, _, _, _ in await gate.value }), portCheck: { _ in })
        var draft = try #require(await manager.catalog().first).defaults
        draft.servedModelName = "a model with spaces"
        let profile = draft
        let pending = try await manager.load(profile)
        #expect(pending.phase == "loading")
        #expect(pending.operationID != nil)
        #expect(pending.mode == "managed")
        #expect(await manager.activeManagedURL()?.port == 8082)
        await gate.set(true)
        try await waitFor(manager, phase: "loaded")
        let launch = try #require(launches.values.first)
        #expect(launch.arguments.contains("--idle"))
        #expect(!launch.arguments.contains("--model"))
        #expect(launch.arguments.contains("--config"))
        #expect(!launch.arguments.contains("sh"))
        #expect((await manager.state()).savedProfiles.isEmpty)
        _ = try await manager.unload()
        try await waitFor(manager, phase: "idle")
        #expect(process.terminations == 0)
        #expect((await manager.state()).processID == process.processIdentifier)
        #expect((await manager.state()).mode == "managed")
        #expect(await manager.activeManagedURL()?.port == 8082)
        _ = try await manager.useExternal()
        #expect(await manager.activeManagedURL() == nil)
        await manager.shutdown()
    }

    @Test func invalidReloadLeavesExistingChildAndProfileUntouched() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let launches = LaunchRecorder(child: process)
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { launches.launch($0) }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        var invalid = profile
        invalid.contextLength = 131073
        do {
            _ = try await manager.load(invalid)
            Issue.record("Invalid reload should fail")
        } catch { #expect(error is ModelControlError) }
        #expect(process.terminations == 0)
        #expect(launches.values.count == 1)
        #expect((await manager.state()).activeProfile == profile)
        await manager.shutdown()
    }

    @Test func busyOperationsDoNotTerminateALoadingRunner() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let process = FakeControlChild()
        let launches = LaunchRecorder(child: process)
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { launches.launch($0) }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in false }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        for _ in 0..<100 {
            if !launches.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        do {
            _ = try await manager.load(profile)
            Issue.record("Concurrent load should fail")
        } catch let error as ModelControlError { #expect(error.code == "busy") }
        do {
            _ = try await manager.unload()
            Issue.record("Concurrent unload should fail")
        } catch let error as ModelControlError { #expect(error.code == "busy") }
        #expect(process.terminations == 0)
        #expect((await manager.state()).processID == process.processIdentifier)
        await manager.shutdown()
        #expect(process.terminations == 1)
    }

    @Test func timeoutAndUnexpectedExitAreReportedWithBoundedLogs() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration.startupTimeout = 0.03
        let process = FakeControlChild()
        process.addLogs(Array(repeating: String(repeating: "x", count: 4000), count: 300))
        let manager = ModelControlManager(
            configuration: configuration,
            launcher: { _ in process }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in false }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "error")
        let state = await manager.state()
        #expect(state.lastError?.contains("timed out") == true)
        #expect(state.logs.count <= 160)
        #expect(state.logs.allSatisfy { $0.count <= 2048 })
        #expect(process.terminations == 0)
        #expect(state.processID == process.processIdentifier)
        #expect(state.mode == "managed")
        await manager.shutdown()

        let exited = FakeControlChild()
        let second = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in exited }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }),
            portCheck: { _ in })
        _ = try await second.load(profile)
        try await waitFor(second, phase: "loaded")
        exited.exit(17)
        #expect((await second.state()).lastError?.contains("status 17") == true)
        #expect((await second.state()).phase == "error")
        await second.shutdown()
    }

    @Test func occupiedPortAndMissingBinaryDoNotAdoptExternalProcess() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in
                Issue.record("Port conflict must prevent launching")
                return FakeControlChild()
            },
            runtime: FakeControlRuntime(readiness: { _, _, _, _ in
                Issue.record("Port conflict must not probe another process")
                return true
            }),
            portCheck: { _ in throw ModelControlError("Port already in use", code: "port_unavailable", status: 409) })
        let profile = try #require(await manager.catalog().first).defaults
        do {
            _ = try await manager.load(profile)
            Issue.record("Occupied port should fail")
        } catch let error as ModelControlError { #expect(error.code == "port_unavailable") }
        #expect((await manager.state()).mode == "external")
        #expect((await manager.state()).processID == nil)
        await manager.shutdown()
    }

    @Test func cancelledServiceStillForcesUnresponsiveOwnedChildToExit() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let child = FakeControlChild(ignoreTermination: true)
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        let cleanup = Task { await manager.shutdown() }
        cleanup.cancel()
        await cleanup.value
        #expect(child.terminations == 1)
        #expect(child.forcedTerminations == 1)
        #expect(child.status() == .exited(9))
        #expect((await manager.state()).processID == nil)
    }

    @Test func staleStopCannotSignalTheCurrentOwnedChild() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let child = FakeControlChild()
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        do {
            try await manager.stopOwned(token: UUID())
            Issue.record("Stale stop should be cancelled")
        } catch { #expect(error is CancellationError) }
        #expect(child.terminations == 0)
        #expect(child.forcedTerminations == 0)
        #expect((await manager.state()).phase == "loaded")
        await manager.shutdown()
    }

    @Test func servedNameAndStableLaunchIdentityReachTheRuntimeAPI() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        let child = FakeControlChild()
        let launches = LaunchRecorder(child: child)
        let manager = ModelControlManager(
            configuration: fixture.configuration,
            launcher: { launches.launch($0) },
            runtime: FakeControlRuntime(readiness: { _, name, instanceID, processID in
                #expect(name == "--port=9000")
                #expect(UUID(uuidString: instanceID) != nil)
                #expect(instanceID == launches.values.last?.instanceID)
                #expect(processID == child.processIdentifier)
                return true
            }), portCheck: { _ in })
        var profile = try #require(await manager.catalog().first).defaults
        profile.servedModelName = "--port=9000"
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        let arguments = try #require(launches.values.first).arguments
        #expect(arguments.contains("--idle"))
        #expect(!arguments.contains("--port=9000"))
        #expect(!arguments.contains("--name"))
        await manager.shutdown()
    }

    @Test func shutdownRejectsNewMutationsDuringAndAfterCleanup() async throws {
        let fixture = try ControlFixture()
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration.stopTimeout = 0.2
        let child = FakeControlChild(ignoreTermination: true)
        let manager = ModelControlManager(
            configuration: configuration,
            launcher: { _ in child }, runtime: FakeControlRuntime(readiness: { _, _, _, _ in true }),
            portCheck: { _ in })
        let profile = try #require(await manager.catalog().first).defaults
        _ = try await manager.load(profile)
        try await waitFor(manager, phase: "loaded")
        let cleanup = Task { await manager.shutdown() }
        for _ in 0..<100 {
            if child.terminations > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(child.terminations == 1)
        for action in ["load", "save", "unload", "external"] {
            do {
                switch action {
                case "load": _ = try await manager.load(profile)
                case "save": _ = try await manager.save(profile)
                case "unload": _ = try await manager.unload()
                default: _ = try await manager.useExternal()
                }
                Issue.record("Shutdown should reject \(action)")
            } catch let error as ModelControlError { #expect(error.code == "shutting_down") }
        }
        await cleanup.value
        do {
            _ = try await manager.load(profile)
            Issue.record("Shutdown is terminal")
        } catch let error as ModelControlError { #expect(error.code == "shutting_down") }
        #expect(child.terminations == 1)
        #expect(child.forcedTerminations == 1)
        #expect((await manager.state()).savedProfiles.isEmpty)
    }
}

private func waitFor(_ manager: ModelControlManager, phase: String) async throws {
    for _ in 0..<200 {
        if await manager.state().phase == phase { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Expected phase \(phase), got \(await manager.state().phase)")
}

private struct ControlFixture {
    let root: URL
    var models: URL { root.appendingPathComponent("models") }
    var checkpoint: URL { models.appendingPathComponent("Example checkpoint") }
    var configuration: ModelControlConfiguration {
        var configuration = ModelControlConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            modelRoots: [models], stateDirectory: root.appendingPathComponent("state"))
        configuration.pollInterval = 0.005
        configuration.stopTimeout = 0.01
        return configuration
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "midnight-control-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data(
            #"{"model_type":"gpt_oss","num_hidden_layers":24,"max_position_embeddings":131072,"quantization":{"bits":4,"mode":"mxfp4"}}"#
                .utf8
        )
        .write(to: checkpoint.appendingPathComponent("config.json"))
        try Data("metadata".utf8).write(to: checkpoint.appendingPathComponent("model.safetensors"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class FakeControlChild: ModelControlChild, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ModelControlChildStatus = .running
    private var count = 0
    private var forceCount = 0
    private var logs: [String] = []
    private let ignoreTermination: Bool
    init(ignoreTermination: Bool = false) { self.ignoreTermination = ignoreTermination }
    var processIdentifier: Int32 { 4242 }
    var terminations: Int { lock.withLock { count } }
    var forcedTerminations: Int { lock.withLock { forceCount } }
    func status() -> ModelControlChildStatus { lock.withLock { current } }
    func terminate() {
        lock.withLock {
            count += 1
            if !ignoreTermination { current = .exited(0) }
        }
    }
    func forceTerminate() {
        lock.withLock {
            forceCount += 1
            current = .exited(9)
        }
    }
    func exit(_ code: Int32) { lock.withLock { current = .exited(code) } }
    func addLogs(_ value: [String]) { lock.withLock { logs += value } }
    func drainLogs() -> [String] {
        lock.withLock {
            let value = logs
            logs = []
            return value
        }
    }
}

private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelControlLaunch] = []
    let child: FakeControlChild
    init(child: FakeControlChild) { self.child = child }
    var values: [ModelControlLaunch] { lock.withLock { storage } }
    func launch(_ launch: ModelControlLaunch) -> any ModelControlChild {
        lock.withLock { storage.append(launch) }
        return child
    }
}

private actor ReadinessGate {
    var value = false
    func set(_ value: Bool) { self.value = value }
}
