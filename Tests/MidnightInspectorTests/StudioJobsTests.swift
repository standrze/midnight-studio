import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import MidnightInspector

struct StudioJobsTests {
    @Test func datasetValidationRejectsBadRowsAndSplitOverlap() async throws {
        for text in ["", "not json", "{}", #"{"text":""}"#, #"{"text":"x","other":1}"#, "{\"text\":\"x\"}\n{\"text\":\"x\"}"] {
            #expect(throws: ModelControlError.self) { try StudioJobs.validateDataset(text) }
        }
        let fixture = try StudioFixture()
        defer { fixture.remove() }
        let jobs = StudioJobs(configuration: fixture.configuration)
        await #expect(throws: ModelControlError.self) {
            try await jobs.saveDataset(.init(name: "overlap", train: #"{"text":"same"}"#, validation: #"{"text":"same"}"#))
        }
        let saved = try await jobs.saveDataset(.init(name: "Domain", train: #"{"text":"training example"}"#, validation: #"{"text":"held-out example"}"#))
        #expect(saved.datasets.count == 1)
        let restored = StudioJobs(configuration: fixture.configuration)
        #expect(await restored.state().datasets.first?.id == saved.datasets.first?.id)
    }

    @Test func hubManifestPinsCommitAndOmitsExecutableAndNestedFiles() throws {
        let data = try JSONSerialization.data(withJSONObject: ["sha": String(repeating: "a", count: 40), "siblings":
            ["config.json", "model.safetensors", "../../outside.json", "code.py", "pytorch_model.bin", "nested/model.safetensors"].map { ["rfilename": $0] }])
        let manifest = try StudioHub.parseManifest(data, repository: "owner/model")
        #expect(manifest.files == ["config.json", "model.safetensors"])
        for repository in ["https://example.com/model", "owner/../model", "owner/", "../model", "owner/model?token=x"] {
            #expect(throws: ModelControlError.self) { try StudioHub.validate(repository: repository, revision: "main") }
        }
    }

    @Test func streamingDeletesEachSourceBeforeNextAndPublishesCompleteIndex() async throws {
        let fixture = try StudioFixture()
        defer { fixture.remove() }
        let jobs = StudioJobs(configuration: fixture.configuration, launcher: { launch in
            let args = launch.arguments
            let output = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
            let shard = args[args.firstIndex(of: "--shard")! + 1]
            let key = shard.hasSuffix("one.safetensors") ? "one.weight" : "two.weight"
            try Data("quantized".utf8).write(to: output)
            try JSONSerialization.data(withJSONObject: ["keys": [key], "sourceKeys": [key], "expectedKeys": ["one.weight", "two.weight"], "quantization": [:], "totalSize": 9])
                .write(to: output.appendingPathExtension("json"))
            return StudioChild(exited: true)
        }, hub: StudioTestHub())
        _ = try await jobs.start(.init(kind: "stream-quantize", repository: "owner/model", method: "standard"))
        let state = try await completed(jobs)
        let job = try #require(state.jobs.first)
        #expect(job.phase == "completed")
        let output = URL(fileURLWithPath: try #require(job.output))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("model.safetensors.index.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.configuration.studioLibrary.path).count == 1)
        #expect(job.logs.filter { $0.contains("deleted its temporary source") }.count == 2)
    }

    @Test func workerFailureDoesNotPublishAndCancellationWaitsForOwnedChild() async throws {
        let fixture = try StudioFixture()
        defer { fixture.remove() }
        let failed = StudioJobs(configuration: fixture.configuration, launcher: { _ in StudioChild(exited: true, exitCode: 7) }, hub: StudioTestHub())
        _ = try await failed.start(.init(kind: "stream-quantize", repository: "owner/model"))
        #expect(try await completed(failed).jobs.first?.phase == "failed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.configuration.studioLibrary.path).isEmpty)
        let child = StudioChild(exited: false)
        let jobs = StudioJobs(configuration: fixture.configuration, launcher: { _ in child }, hub: StudioTestHub())
        _ = try await jobs.start(.init(kind: "stream-quantize", repository: "owner/model"))
        await #expect(throws: ModelControlError.self) { try await jobs.start(.init(kind: "download", repository: "owner/model")) }
        _ = await jobs.cancel()
        #expect(try await completed(jobs).jobs.first?.phase == "cancelled")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.configuration.studioLibrary.path).isEmpty)
    }

    @Test func studioRoutesEnforceOriginAndContentTypeAndServePreparationPage() async throws {
        let fixture = try StudioFixture()
        defer { fixture.remove() }
        let jobs = StudioJobs(configuration: fixture.configuration, hub: StudioTestHub())
        let server = InspectorServer(configuration: fixture.configuration, studioJobs: jobs)
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(uri: "/prepare", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Stream &amp;") || String(buffer: response.body).contains("Stream & quantize"))
            }
            for route in ["/api/studio/jobs", "/api/studio/datasets", "/api/studio/cancel", "/api/studio/load-adapter"] {
                try await client.execute(uri: route, method: .post, headers: [.contentType: "application/json", .origin: "https://foreign.example"], body: .init(string: "{}")) { response in #expect(response.status == .forbidden) }
                try await client.execute(uri: route, method: .post, headers: [.contentType: "text/plain"], body: .init(string: "{}")) { response in #expect(response.status == .unsupportedMediaType) }
            }
            try await client.execute(uri: "/api/studio/jobs", method: .post, headers: [.contentType: "application/json"], body: .init(string: "{}")) { response in #expect(response.status == .badRequest) }
        }
    }

    @Test func completedTrainingLoadsOnlyItsOwnAdapterWithOriginalBase() async throws {
        let fixture = try StudioFixture()
        defer { fixture.remove() }
        let source = fixture.configuration.studioLibrary.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"model_type":"llama","num_hidden_layers":4,"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        try Data("fixture".utf8).write(to: source.appendingPathComponent("model.safetensors"))
        let jobs = StudioJobs(configuration: fixture.configuration, launcher: { launch in
            let output = URL(fileURLWithPath: launch.arguments[launch.arguments.firstIndex(of: "--output")! + 1])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            for name in ["adapter_config.json", "adapters.safetensors", "studio-training.json"] { try Data("{}".utf8).write(to: output.appendingPathComponent(name)) }
            return StudioChild(exited: true)
        })
        let dataset = try await jobs.saveDataset(.init(name: "fixture", train: #"{"text":"a b"}"#, validation: #"{"text":"a c"}"#))
        let model = try #require(ModelControlCatalog(roots: [fixture.configuration.studioLibrary]).models().first)
        _ = try await jobs.start(.init(kind: "finetune", modelID: model.id, datasetID: dataset.datasets[0].id, learningRate: 0.00001))
        let completedJob = try #require(try await completed(jobs).jobs.first)
        #expect(completedJob.phase == "completed")
        let (profile, adapter) = try await jobs.adapterForJob(completedJob.id)
        #expect(profile.modelID == model.id)
        #expect(adapter.lastPathComponent == "adapter")
        await #expect(throws: ModelControlError.self) { try await jobs.adapterForJob("../../arbitrary") }
        let owned = StudioChild(exited: false)
        var controlConfig = fixture.configuration.controlConfiguration
        controlConfig = ModelControlConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/true"), modelRoots: controlConfig.modelRoots, stateDirectory: controlConfig.stateDirectory, pollInterval: 0.001)
        let runtime = FakeControlRuntime()
        let controls = ModelControlManager(configuration: controlConfig, launcher: { launch in
            #expect(launch.arguments.contains("--idle"))
            return owned
        }, runtime: runtime, portCheck: { _ in })
        _ = try await controls.load(profile, adapter: adapter)
        for _ in 0..<100 {
            if await controls.state().phase == "loaded" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runtime.loadedRequests().last?.adapter == adapter.path)
        #expect(await controls.state().adapterPath == adapter.path)
        #expect(await controls.state().phase == "loaded")
        await controls.shutdown()
    }

    private func completed(_ jobs: StudioJobs) async throws -> StudioState {
        for _ in 0..<300 {
            let state = await jobs.state()
            if let phase = state.jobs.first?.phase, !["running", "cancelling"].contains(phase) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelControlError("Fixture timed out")
    }
}

private struct StudioFixture {
    let root: URL
    var configuration: InspectorConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
        configuration = try InspectorConfiguration(arguments: ["--state-directory", root.appendingPathComponent("state").path,
            "--studio-library", root.appendingPathComponent("models").path, "--model-root", root.appendingPathComponent("models").path,
            "--trainer-binary", "/usr/bin/true"])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct StudioTestHub: StudioHubClient {
    func manifest(repository: String, revision: String) async throws -> StudioHubManifest {
        .init(repository: repository, commit: String(repeating: "a", count: 40), files: ["config.json", "one.safetensors", "two.safetensors"], sizes: [:], hashes: [:])
    }
    func download(repository: String, commit: String, file: String, into directory: URL, expectedSize: Int64?, expectedHash: String?) async throws {
        if file == "two.safetensors" {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("one.safetensors").path))
        }
        let value = file == "config.json" ? #"{"model_type":"llama"}"# : "weights"
        try Data(value.utf8).write(to: directory.appendingPathComponent(file))
    }
}

private final class StudioChild: ModelControlChild, @unchecked Sendable {
    private let lock = NSLock()
    private var exited: Bool
    let exitCode: Int32
    let processIdentifier: Int32 = 900000
    init(exited: Bool, exitCode: Int32 = 0) { self.exited = exited; self.exitCode = exitCode }
    func status() -> ModelControlChildStatus { lock.withLock { exited ? .exited(exitCode) : .running } }
    func terminate() { lock.withLock { exited = true } }
    func forceTerminate() { terminate() }
    func drainLogs() -> [String] { [] }
}
