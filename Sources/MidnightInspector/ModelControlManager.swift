import Foundation

struct ModelControlState: Codable, Sendable {
    let mode: String
    let phase: String
    let message: String
    let endpoint: String
    let activeProfile: ModelControlProfile?
    let savedProfiles: [ModelControlProfile]
    let operationID: String?
    let logs: [String]
    let processID: Int32?
    let lastError: String?
    var adapterPath: String? = nil
}

struct ModelControlRoutingState: Sendable {
    let revision: String
    let mode: String
    let phase: String
    let url: URL
}

/// Serializes ownership changes, with loading and shutdown work running outside
/// the HTTP request. Browser requests can select catalog IDs, never executables,
/// arbitrary arguments, host addresses, or process IDs.
actor ModelControlManager {
    typealias Launcher = @Sendable (ModelControlLaunch) throws -> any ModelControlChild
    typealias PortCheck = @Sendable (Int) throws -> Void

    private let configuration: ModelControlConfiguration
    private let modelCatalog: ModelControlCatalog
    private let launcher: Launcher
    private let runtime: any ModelControlRuntime
    private var instanceID: String?
    private var modelGeneration: UInt64?
    private var routingRevision = UUID()
    private let portCheck: PortCheck
    private var child: (any ModelControlChild)?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var mode = "external"
    private var phase = "idle"
    private var message = "Using the configured external Midnight server."
    private var activeProfile: ModelControlProfile?
    private var activeAdapter: URL?
    private var profiles: [ModelControlProfile]
    private var operationID: String?
    private var expectedRuntimeOperationID: String?
    private var rejectedLoadError: String?
    private struct PreviousLoadedModel: Sendable {
        let profile: ModelControlProfile
        let adapter: URL?
        let operationID: String?
        let modelGeneration: UInt64?
    }
    private var logs: [String] = []
    private var lastError: String?
    private var shuttingDown = false
    private var shutdownOperation: Task<Void, Never>?

    init(configuration: ModelControlConfiguration, launcher: Launcher? = nil,
         runtime: any ModelControlRuntime = ModelControlRuntimeClient(), portCheck: PortCheck? = nil) {
        self.configuration = configuration
        modelCatalog = ModelControlCatalog(roots: configuration.modelRoots)
        self.launcher = launcher ?? { try ModelControlProcess($0) }
        self.runtime = runtime
        self.portCheck = portCheck ?? { try ModelControlProcess.requireAvailablePort($0) }
        let file = configuration.stateDirectory.appendingPathComponent("profiles.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
           let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ModelControlProfile].self, from: data) {
            profiles = Array(saved.prefix(500))
        } else { profiles = [] }
    }

    func catalog() -> [ModelControlModel] { modelCatalog.models() }

    func state() -> ModelControlState {
        collectLogs()
        if case .exited(let code) = child?.status() {
            child = nil
            phase = "error"
            lastError = "Managed Midnight exited with status \(code). Review its logs and load the model again."
            message = lastError!
            appendLog(message)
        }
        return snapshot()
    }

    func activeManagedURL() -> URL? { mode == "managed" ? configuration.managedURL : nil }

    func routingState() -> ModelControlRoutingState {
        _ = state()
        return ModelControlRoutingState(revision: routingRevision.uuidString, mode: mode, phase: phase,
            url: mode == "managed" ? configuration.managedURL : configuration.externalURL)
    }

    func save(_ profile: ModelControlProfile) throws -> ModelControlState {
        try requireAvailable()
        _ = try modelCatalog.validate(profile)
        var updated = profiles.filter { $0.modelID != profile.modelID }
        guard updated.count < 500 else { throw ModelControlError("The saved profile limit has been reached.") }
        updated.append(profile)
        do {
            try prepareStateDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writePrivate(encoder.encode(updated), to: configuration.stateDirectory.appendingPathComponent("profiles.json"))
        } catch {
            throw ModelControlError("Could not save the profile: \(error.localizedDescription)", code: "storage_error", status: 500)
        }
        profiles = updated
        return state()
    }

    func load(_ profile: ModelControlProfile, adapter: URL? = nil) throws -> ModelControlState {
        try requireAvailable()
        guard phase != "loading" && phase != "stopping" else { throw busy() }
        let model = try modelCatalog.validate(profile)
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw ModelControlError("The configured Midnight executable is unavailable at \(configuration.executableURL.path). Build Midnight or start Inspector with --midnight-binary PATH.", code: "launch_unavailable", status: 503)
        }
        // Check a foreign port before changing state or releasing a loaded model.
        if child?.status() != .running { try portCheck(configuration.managedPort) }
        do { try prepareStateDirectory(); try writeRuntimeSettings() }
        catch { throw ModelControlError("Could not prepare the managed runtime: \(error.localizedDescription)", code: "storage_error", status: 500) }
        let previous = phase == "loaded" ? activeProfile.map {
            PreviousLoadedModel(profile: $0, adapter: activeAdapter, operationID: expectedRuntimeOperationID, modelGeneration: modelGeneration)
        } : nil
        operation?.cancel()
        generation = UUID()
        routingRevision = UUID()
        let token = generation
        mode = "managed"
        phase = "loading"
        message = "Loading \(model.name)…"
        activeProfile = profile
        activeAdapter = adapter
        operationID = token.uuidString
        expectedRuntimeOperationID = nil
        rejectedLoadError = nil
        lastError = nil
        appendLog(message)
        operation = Task { await self.performLoad(profile, model: model, token: token, adapter: adapter, previous: previous) }
        return snapshot()
    }

    func unload() throws -> ModelControlState {
        try requireAvailable()
        if child == nil && phase != "loading" && phase != "stopping" {
            if mode == "managed" { phase = "idle"; message = "Managed model is unloaded."; activeProfile = nil; lastError = nil }
            return snapshot()
        }
        guard phase != "loading" && phase != "stopping" else { throw busy() }
        operation?.cancel()
        generation = UUID()
        routingRevision = UUID()
        let token = generation
        phase = "stopping"
        message = "Releasing the managed model…"
        operationID = token.uuidString
        expectedRuntimeOperationID = nil
        rejectedLoadError = nil
        lastError = nil
        operation = Task { await self.performUnload(token: token) }
        return snapshot()
    }

    func useExternal() throws -> ModelControlState {
        try requireAvailable()
        mode = "external"
        return beginStop(external: true)
    }

    func shutdown() async {
        if let shutdownOperation { await shutdownOperation.value; return }
        shuttingDown = true
        operation?.cancel()
        generation = UUID()
        routingRevision = UUID()
        let token = generation
        phase = "stopping"
        message = "Inspector is shutting down and releasing its managed model…"
        operationID = token.uuidString
        // Service shutdown can arrive on an already-cancelled task. A fresh
        // task still performs the bounded owned-child cleanup in that case.
        let cleanup = Task { await self.performShutdown(token: token) }
        shutdownOperation = cleanup
        await cleanup.value
    }

    private func performShutdown(token: UUID) async {
        do {
            try await stopOwned(token: token)
            phase = "idle"
            activeProfile = nil
            operationID = nil
            message = "Inspector is shutting down."
        } catch { fail(error) }
        operation = nil
    }

    private func beginStop(external: Bool) -> ModelControlState {
        operation?.cancel()
        generation = UUID()
        routingRevision = UUID()
        let token = generation
        lastError = nil
        if child == nil {
            phase = "idle"
            activeProfile = nil
            operationID = nil
            message = external ? "Using the configured external Midnight server." : "Managed model is unloaded."
            return snapshot()
        }
        phase = "stopping"
        message = "Releasing the managed model…"
        operationID = token.uuidString
        operation = Task { await self.performStop(token: token, external: external) }
        return snapshot()
    }

    private func performStop(token: UUID, external: Bool) async {
        do {
            try await stopOwned(token: token)
            guard token == generation else { return }
            phase = "idle"
            activeProfile = nil
            operationID = nil
            message = external ? "Using the configured external Midnight server." : "Managed model is unloaded."
            appendLog(message)
        } catch {
            guard token == generation else { return }
            fail(error)
        }
    }

    private func performLoad(_ profile: ModelControlProfile, model: ModelControlModel, token: UUID, adapter: URL?, previous: PreviousLoadedModel?) async {
        do {
            try checkCurrent(token)
            if child?.status() != .running {
                try portCheck(configuration.managedPort)
                let identity = UUID().uuidString
                child = try launcher(ModelControlLaunch(
                    executableURL: configuration.executableURL,
                    arguments: ["--config", configuration.stateDirectory.appendingPathComponent("managed-runtime.json").path,
                                "--idle", "--host", "127.0.0.1", "--port", String(configuration.managedPort)],
                    workingDirectory: configuration.stateDirectory, instanceID: identity))
                instanceID = identity
                modelGeneration = nil
            }
            _ = try await waitForRuntime(token: token)
            try checkCurrent(token)
            let current = try modelCatalog.validate(profile)
            guard current.path == model.path else { throw ModelControlError("The selected model folder changed. Refresh the catalog.") }
            let owned = try ownedRuntime()
            let accepted: ManagedRuntimeState
            do {
                accepted = try await runtime.load(ManagedModelRequest(
                    model: model.path, name: profile.servedModelName, adapter: adapter?.path,
                    maxTokens: profile.maximumTokens, contextLength: profile.contextLength,
                    prefillStepSize: profile.prefillStepSize, kvCompression: profile.kvCompression, engine: profile.engine),
                    at: configuration.managedURL, instanceID: owned.0, processID: owned.1)
            } catch {
                if await restoreRejectedLoad(error, previous: previous, token: token) {
                    await monitor(token: token)
                    return
                }
                throw error
            }
            try checkCurrent(token)
            guard let acceptedID = accepted.operationID else { throw ModelControlError("Midnight did not identify the accepted load operation.") }
            operationID = acceptedID
            expectedRuntimeOperationID = acceptedID
            try await waitForOperation(acceptedID, modelName: profile.servedModelName, token: token)
            phase = "loaded"
            message = "\(profile.servedModelName) is loaded and ready." + (adapter == nil ? "" : " Using the Studio-trained LoRA adapter.")
            lastError = nil
            operationID = nil
            appendLog(message)
            await monitor(token: token)
        } catch {
            guard token == generation else { return }
            // A model failure leaves the owned runner available for another load.
            fail(error)
            await monitor(token: token)
        }
    }

    private func restoreRejectedLoad(_ error: Error, previous: PreviousLoadedModel?, token: UUID) async -> Bool {
        // Only an explicit preflight rejection proves that the requested load was
        // not accepted. Network errors and later load failures remain uncertain.
        guard let rejection = error as? ModelControlError,
              rejection.code == "runtime_error", rejection.status == 400,
              let previous, let value = try? await readRuntime(token: token),
              value.phase == "ready", value.loadedModel?.id == previous.profile.servedModelName,
              value.operationID == previous.operationID, value.modelGeneration == previous.modelGeneration else { return false }
        activeProfile = previous.profile
        activeAdapter = previous.adapter
        expectedRuntimeOperationID = previous.operationID
        rejectedLoadError = rejection.message
        lastError = rejection.message
        operationID = nil
        phase = "loaded"
        message = "Could not load the selected model: \(rejection.message) \(previous.profile.servedModelName) remains loaded and ready."
        appendLog(message)
        return true
    }

    private func performUnload(token: UUID) async {
        do {
            let owned = try ownedRuntime()
            let accepted = try await runtime.unload(at: configuration.managedURL, instanceID: owned.0, processID: owned.1)
            try checkCurrent(token)
            guard let acceptedID = accepted.operationID else { throw ModelControlError("Midnight did not identify the accepted unload operation.") }
            operationID = acceptedID
            expectedRuntimeOperationID = acceptedID
            try await waitForOperation(acceptedID, modelName: nil, token: token)
            phase = "idle"
            activeProfile = nil
            activeAdapter = nil
            operationID = nil
            lastError = nil
            message = "Managed model is unloaded. Midnight is ready to load another model."
            appendLog(message)
            await monitor(token: token)
        } catch {
            guard token == generation else { return }
            fail(error)
            await monitor(token: token)
        }
    }

    private func ownedRuntime() throws -> (String, Int32) {
        guard let instanceID, let child, child.status() == .running else {
            throw ModelControlError("The managed Midnight process is no longer running.", code: "runtime_exited", status: 503)
        }
        return (instanceID, child.processIdentifier)
    }

    private func readRuntime(token: UUID) async throws -> ManagedRuntimeState {
        try checkCurrent(token)
        let owned = try ownedRuntime()
        let value = try await runtime.state(at: configuration.managedURL, instanceID: owned.0, processID: owned.1)
        try checkCurrent(token)
        if modelGeneration != value.modelGeneration {
            modelGeneration = value.modelGeneration
            routingRevision = UUID()
        }
        return value
    }

    private func waitForRuntime(token: UUID) async throws -> ManagedRuntimeState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.startupTimeout))
        while ContinuousClock.now < deadline {
            try checkCurrent(token)
            _ = try ownedRuntime()
            do { return try await readRuntime(token: token) }
            catch let error as ModelControlError where error.code == "runtime_identity_mismatch" { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { }
            try await Task.sleep(for: .seconds(configuration.pollInterval))
        }
        throw ModelControlError("Midnight runtime startup timed out. Review its logs.", code: "load_timeout", status: 504)
    }

    private func waitForOperation(_ acceptedID: String, modelName: String?, token: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.startupTimeout))
        while ContinuousClock.now < deadline {
            let value = try await readRuntime(token: token)
            collectLogs()
            guard value.operationID == acceptedID else {
                throw ModelControlError("The model operation was superseded. Refresh the runtime before trying again.", code: "operation_changed", status: 409)
            }
            if value.phase == "empty", let error = value.lastError { throw ModelControlError(error, code: "load_failed", status: 500) }
            if let modelName {
                if value.phase == "ready", value.loadedModel?.id == modelName { return }
            } else if value.phase == "empty", value.loadedModel == nil { return }
            try await Task.sleep(for: .seconds(configuration.pollInterval))
        }
        throw ModelControlError("The model operation timed out. Midnight remains running; review its logs before trying again.", code: "load_timeout", status: 504)
    }

    private func monitor(token: UUID) async {
        while token == generation && !Task.isCancelled {
            _ = state()
            if child == nil { return }
            do {
                let value = try await readRuntime(token: token)
                if let expectedRuntimeOperationID, value.operationID != expectedRuntimeOperationID {
                    throw ModelControlError("The model operation changed outside Studio. Load a model to resume inspection.", code: "operation_changed", status: 409)
                }
                if value.phase == "empty" {
                    rejectedLoadError = nil
                    activeProfile = nil
                    activeAdapter = nil
                    if let error = value.lastError { fail(ModelControlError(error)) }
                    else { phase = "idle"; lastError = nil; message = "Managed model is unloaded." }
                } else if value.phase != "ready" {
                    if phase != "error" { phase = value.phase == "loading" ? "loading" : "stopping" }
                } else if value.loadedModel?.id != activeProfile?.servedModelName {
                    fail(ModelControlError("The managed model changed outside Studio. Load a model to resume inspection."))
                } else { phase = "loaded"; lastError = rejectedLoadError; operationID = nil }
                try await Task.sleep(for: .seconds(max(configuration.pollInterval, 0.1)))
            } catch is CancellationError { return }
            catch {
                guard token == generation else { return }
                fail(error)
                do { try await Task.sleep(for: .seconds(max(configuration.pollInterval, 0.1))) }
                catch { return }
            }
        }
    }

    func stopOwned(token: UUID) async throws {
        // A superseded task can start late. Check its generation before it can
        // even inspect or signal the currently owned (possibly newer) child.
        try checkCurrent(token)
        guard let owned = child else { return }
        collectLogs()
        if owned.status() == .running {
            owned.terminate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.stopTimeout))
            while owned.status() == .running && ContinuousClock.now < deadline {
                try checkCurrent(token)
                try await Task.sleep(for: .milliseconds(50))
            }
            try checkCurrent(token)
            if owned.status() == .running {
                appendLog("Managed Midnight did not exit after termination; stopping the owned child.")
                owned.forceTerminate()
                let finalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while owned.status() == .running && ContinuousClock.now < finalDeadline {
                    try checkCurrent(token)
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        try checkCurrent(token)
        collectLogs()
        guard owned.status() != .running else {
            throw ModelControlError("The managed Midnight process has not exited; a second model will not be launched.", code: "stop_failed", status: 500)
        }
        child = nil
        instanceID = nil
        modelGeneration = nil
    }

    private func prepareStateDirectory() throws {
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func writeRuntimeSettings() throws {
        // Prevent unrelated auto-discovered model-stack settings from supplying
        // an adapter or drafter, or overriding the managed runtime's policy.
        try writePrivate(Data("{}\n".utf8), to: configuration.stateDirectory.appendingPathComponent("managed-runtime.json"))
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func checkCurrent(_ token: UUID) throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
    }
    private func requireAvailable() throws {
        guard !shuttingDown else {
            throw ModelControlError("Inspector is shutting down and cannot accept another model operation.", code: "shutting_down", status: 503)
        }
    }
    private func fail(_ error: Error) {
        phase = "error"
        operationID = nil
        lastError = error.localizedDescription
        message = error.localizedDescription
        appendLog(message)
    }
    private func busy() -> ModelControlError {
        ModelControlError("A model operation is already running. Wait for it to finish before loading or unloading a model.", code: "busy", status: 409)
    }
    private func collectLogs() { for line in child?.drainLogs() ?? [] { appendLog(line) } }
    private func appendLog(_ line: String) {
        logs.append(String(line.prefix(2048)))
        if logs.count > 160 { logs.removeFirst(logs.count - 160) }
    }
    private func exitDescription(_ status: ModelControlChildStatus?) -> String {
        if case .exited(let code) = status { return " (exit \(code))" }
        return ""
    }
    private func snapshot() -> ModelControlState {
        ModelControlState(mode: mode, phase: phase, message: message,
            endpoint: (mode == "managed" ? configuration.managedURL : configuration.externalURL).absoluteString,
            activeProfile: activeProfile, savedProfiles: profiles, operationID: operationID, logs: logs,
            processID: child?.status() == .running ? child?.processIdentifier : nil, lastError: lastError,
            adapterPath: activeProfile == nil ? nil : activeAdapter?.path)
    }
}
