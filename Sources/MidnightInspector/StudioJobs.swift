import Foundation

struct StudioJobRequest: Codable, Sendable {
    var kind: String
    var repository: String?
    var revision: String?
    var modelID: String?
    var datasetID: String?
    var method: String?
    var iterations: Int?
    var learningRate: Double?
    var layers: Int?
    var rank: Int?
    var sequenceLength: Int?
}

struct StudioJob: Codable, Sendable {
    var id: String
    var request: StudioJobRequest
    var phase: String
    var createdAt: Date
    var message: String
    var output: String?
    var logs: [String] = []
}

struct StudioDatasetRequest: Codable, Sendable {
    var name: String
    var train: String
    var validation: String
}

struct StudioAdapterRequest: Decodable, Sendable { var jobID: String }

struct StudioDataset: Codable, Sendable {
    var id: String
    var name: String
    var trainingExamples: Int
    var validationExamples: Int
}

struct StudioState: Codable, Sendable {
    var jobs: [StudioJob]
    var datasets: [StudioDataset]
    var quantizerAvailable: Bool
    var trainerAvailable: Bool
    var libraryPath: String
}

/// Job inputs select catalog records. Executables and output roots are fixed at launch.
/// Downloads remain hidden until complete; every conversion/training job owns a fresh output.
actor StudioJobs {
    typealias Launcher = ModelControlManager.Launcher
    private let directory: URL
    private let library: URL
    private let catalog: ModelControlCatalog
    private let quantizer: URL
    private let trainer: URL
    private let launcher: Launcher
    private let hub: any StudioHubClient
    private var jobs: [StudioJob] = []
    private var datasets: [StudioDataset] = []
    private var operation: Task<Void, Never>?
    private var child: (any ModelControlChild)?
    private var closing = false

    init(configuration: InspectorConfiguration, launcher: Launcher? = nil, hub: any StudioHubClient = StudioHub()) {
        directory = configuration.stateDirectory.appendingPathComponent("studio")
        library = configuration.studioLibrary
        catalog = ModelControlCatalog(roots: configuration.modelRoots + [configuration.studioLibrary])
        quantizer = configuration.quantizerBinary
        trainer = configuration.trainerBinary
        self.launcher = launcher ?? { try ModelControlProcess($0) }
        self.hub = hub
        if let data = try? Data(contentsOf: directory.appendingPathComponent("jobs.json")), data.count <= 4 * 1024 * 1024,
           let saved = try? JSONDecoder().decode([StudioJob].self, from: data) {
            jobs = Array(saved.prefix(50)).map { job in
                var job = job
                if ["running", "cancelling"].contains(job.phase) {
                    job.phase = "interrupted"; job.message = "Studio stopped before this job completed. Start a new job."
                }
                return job
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("datasets.json")), data.count <= 1024 * 1024,
           let saved = try? JSONDecoder().decode([StudioDataset].self, from: data) { datasets = Array(saved.prefix(100)) }
    }

    func state() -> StudioState {
        .init(jobs: jobs, datasets: datasets,
              quantizerAvailable: FileManager.default.isExecutableFile(atPath: quantizer.path),
              trainerAvailable: FileManager.default.isExecutableFile(atPath: trainer.path), libraryPath: library.path)
    }

    func adapterForJob(_ id: String) throws -> (ModelControlProfile, URL) {
        guard let job = jobs.first(where: { $0.id == id && $0.phase == "completed" && ["finetune", "cpt"].contains($0.request.kind) }),
              let model = catalog.models().first(where: { $0.id == job.request.modelID }) else {
            throw ModelControlError("Select a completed training job whose base model is still available.")
        }
        let adapter = directory.appendingPathComponent("runs/\(job.id)/adapter").resolvingSymlinksInPath()
        guard ModelControlCatalog.contains(adapter, in: directory.resolvingSymlinksInPath()),
              job.output.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == adapter.path,
              ["adapters.safetensors", "adapter_config.json", "studio-training.json"].allSatisfy({ name in
                  let file = adapter.appendingPathComponent(name).resolvingSymlinksInPath()
                  return ModelControlCatalog.contains(file, in: adapter) && FileManager.default.fileExists(atPath: file.path)
              }) else { throw ModelControlError("The completed adapter files are unavailable.") }
        var profile = model.defaults
        profile.servedModelName = String(model.name.prefix(90)) + "-" + job.request.kind + "-" + job.id.prefix(8)
        return (profile, adapter)
    }

    static func validateDataset(_ text: String) throws -> [String] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw ModelControlError("Each dataset split must be at most 2 MiB.") }
        var examples: [String] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  Set(object.keys) == ["text"], let value = object["text"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 65536 else {
                throw ModelControlError("Line \(index + 1) must be a JSON object with one nonempty text field (at most 64 KiB).")
            }
            examples.append(value)
            guard examples.count <= 10000 else { throw ModelControlError("Each split supports up to 10,000 examples.") }
        }
        guard !examples.isEmpty else { throw ModelControlError("Training and validation both need examples.") }
        guard Set(examples).count == examples.count else { throw ModelControlError("Remove duplicate examples within each split.") }
        return examples
    }

    func saveDataset(_ request: StudioDatasetRequest) throws -> StudioState {
        guard !closing, datasets.count < 100, (1...80).contains(request.name.count) else {
            throw ModelControlError("Use a dataset name of 1–80 characters; up to 100 datasets can be stored.")
        }
        let train = try Self.validateDataset(request.train)
        let valid = try Self.validateDataset(request.validation)
        guard Set(train).isDisjoint(with: Set(valid)) else { throw ModelControlError("Training and validation splits must not share examples.") }
        let dataset = StudioDataset(id: UUID().uuidString, name: request.name,
                                    trainingExamples: train.count, validationExamples: valid.count)
        let folder = directory.appendingPathComponent("datasets/\(dataset.id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(request.train.utf8).write(to: folder.appendingPathComponent("train.jsonl"), options: .atomic)
        try Data(request.validation.utf8).write(to: folder.appendingPathComponent("valid.jsonl"), options: .atomic)
        datasets.append(dataset)
        do { try persist() } catch { datasets.removeLast(); throw error }
        return state()
    }

    func start(_ request: StudioJobRequest) throws -> StudioState {
        guard !closing, operation == nil else { throw ModelControlError("A preparation job is already running. Wait or cancel it first.", code: "busy", status: 409) }
        guard ["download", "stream-quantize", "quantize", "finetune", "cpt"].contains(request.kind) else { throw ModelControlError("Unknown Studio job type.") }
        let id = UUID().uuidString
        var model: ModelControlModel?
        if request.kind == "download" || request.kind == "stream-quantize" {
            try StudioHub.validate(repository: request.repository ?? "", revision: request.revision ?? "main")
            if request.kind == "stream-quantize" {
                guard FileManager.default.isExecutableFile(atPath: trainer.path) else { throw ModelControlError("Build midnight-studio-worker to enable streaming quantization.", status: 503) }
                guard ["scalesearch", "standard"].contains(request.method ?? "scalesearch") else { throw ModelControlError("Unknown quantization method.") }
            }
        } else {
            guard let selected = catalog.models().first(where: { $0.id == request.modelID }) else { throw ModelControlError("Select an available local model.") }
            guard selected.supported else { throw ModelControlError(selected.warning ?? "Select a supported text checkpoint.") }
            model = selected
            let executable = request.kind == "quantize" ? quantizer : trainer
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ModelControlError("Build \(executable.lastPathComponent) first, then restart Studio or set its worker path at launch.", code: "worker_unavailable", status: 503)
            }
            if request.kind == "quantize" {
                guard selected.quantization == nil else { throw ModelControlError("Select an unquantized source. Requantization is unsupported.") }
                guard ["scalesearch", "standard"].contains(request.method ?? "scalesearch") else { throw ModelControlError("Choose ScaleSearch or standard Q4.") }
            } else {
                guard selected.supported else { throw ModelControlError(selected.warning ?? "Choose a text model.") }
                guard datasets.contains(where: { $0.id == request.datasetID }) else { throw ModelControlError("Select a validated dataset.") }
                guard (1...100000).contains(request.iterations ?? 100),
                      (1...min(selected.layerCount ?? 1, 128)).contains(request.layers ?? 4),
                      [4, 8, 16, 32, 64].contains(request.rank ?? 8),
                      (32...2048).contains(request.sequenceLength ?? 512),
                      let rate = request.learningRate, rate.isFinite, (0.0000001...0.001).contains(rate) else {
                    throw ModelControlError("Invalid training settings. Use 1–100,000 steps, valid layer count, rank 4–64, 32–2,048 tokens, and learning rate 1e-7–1e-3.")
                }
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let job = StudioJob(id: id, request: request, phase: "running", createdAt: Date(), message: "Preparing \(request.kind)…")
        jobs.insert(job, at: 0)
        jobs = Array(jobs.prefix(50))
        try persist()
        operation = Task { await self.run(id: id, request: request, model: model) }
        return state()
    }

    func cancel() -> StudioState {
        guard operation != nil else { return state() }
        jobs[0].phase = "cancelling"
        jobs[0].message = "Cancelling the current job…"
        operation?.cancel()
        child?.terminate()
        return state()
    }

    func shutdown() async {
        closing = true
        _ = cancel()
        await operation?.value
    }

    private func run(id: String, request: StudioJobRequest, model: ModelControlModel?) async {
        let workspace = directory.appendingPathComponent("runs/\(id)")
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let output: URL
            if request.kind == "stream-quantize" {
                output = try await streamQuantize(id: id, request: request, workspace: workspace)
            } else if request.kind == "download" {
                let staging = library.appendingPathComponent(".download-\(id)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                let repo = request.repository!
                let manifest = try await hub.manifest(repository: repo, revision: request.revision ?? "main")
                for (index, file) in manifest.files.enumerated() {
                    try Task.checkCancellation()
                    update("Downloading \(index + 1)/\(manifest.files.count): \(file)")
                    try await hub.download(repository: repo, commit: manifest.commit, file: file, into: staging,
                                           expectedSize: manifest.sizes[file], expectedHash: manifest.hashes[file])
                }
                try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("studio-source.json"))
                try Task.checkCancellation()
                output = library.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--") + "-" + id.prefix(8))
                try FileManager.default.moveItem(at: staging, to: output)
            } else {
                guard let model else { throw ModelControlError("The source model is unavailable.") }
                output = request.kind == "quantize" ? library.appendingPathComponent("\(model.name)-q4-\(id.prefix(8))") : workspace.appendingPathComponent("adapter")
                let staging = workspace.appendingPathComponent(request.kind == "quantize" ? "checkpoint" : "adapter")
                var arguments: [String]
                if request.kind == "quantize" {
                    arguments = [model.path, staging.path]
                    if request.method == "standard" { arguments.append("--standard-q4") }
                } else {
                    arguments = ["train", "--model", model.path, "--data", directory.appendingPathComponent("datasets/\(request.datasetID!)").path,
                                 "--output", staging.path, "--mode", request.kind,
                                 "--iterations", String(request.iterations ?? 100), "--learning-rate", String(request.learningRate!),
                                 "--layers", String(request.layers ?? 4), "--rank", String(request.rank ?? 8),
                                 "--sequence-length", String(request.sequenceLength ?? 512)]
                }
                try Task.checkCancellation()
                child = try launcher(.init(executableURL: request.kind == "quantize" ? quantizer : trainer,
                                           arguments: arguments, workingDirectory: workspace, instanceID: id))
                update("Running \(request.kind) on \(model.name). Output: \(staging.path)")
                while child?.status() == .running {
                    collectLogs()
                    try await Task.sleep(for: .milliseconds(300))
                }
                collectLogs()
                guard case .exited(0) = child?.status() else { throw ModelControlError("Worker failed. Review the job log; incomplete output remains in \(workspace.path).") }
                child = nil
                try Task.checkCancellation()
                let required = request.kind == "quantize" ? "config.json" : "adapters.safetensors"
                guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(required).path) else { throw ModelControlError("Worker exited without its required output file.") }
                if request.kind == "quantize" { try FileManager.default.moveItem(at: staging, to: output) }
            }
            jobs[0].phase = "completed"
            jobs[0].output = output.path
            update("Completed. Saved to \(output.path)")
        } catch {
            if let owned = child {
                owned.terminate()
                // Cancellation must not bypass cleanup. Wait on a fresh task.
                await Task.detached {
                    for _ in 0..<40 where owned.status() == .running { try? await Task.sleep(for: .milliseconds(50)) }
                    if owned.status() == .running { owned.forceTerminate() }
                    for _ in 0..<40 where owned.status() == .running { try? await Task.sleep(for: .milliseconds(50)) }
                }.value
                collectLogs()
            }
            jobs[0].phase = Task.isCancelled ? "cancelled" : "failed"
            update(Task.isCancelled ? "Job cancelled. Partial output is not added to the model library." : error.localizedDescription)
        }
        if child?.status() == .running {
            update("Worker has not exited. Restart Studio only after the worker has stopped.")
            closing = true
        } else { child = nil }
        operation = nil
        do { try persist() } catch { update("Could not save job history: \(error.localizedDescription)") }
    }

    private func update(_ message: String) {
        guard !jobs.isEmpty else { return }
        jobs[0].message = message
        jobs[0].logs.append(String(message.prefix(2048)))
        jobs[0].logs = Array(jobs[0].logs.suffix(160))
    }

    private func streamQuantize(id: String, request: StudioJobRequest, workspace: URL) async throws -> URL {
        let repo = request.repository!
        let manifest = try await hub.manifest(repository: repo, revision: request.revision ?? "main")
        let source = library.appendingPathComponent(".stream-source-\(id)")
        let output = library.appendingPathComponent(".stream-output-\(id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        // Inspect architecture before downloading any weights.
        try await hub.download(repository: repo, commit: manifest.commit, file: "config.json", into: source,
                               expectedSize: manifest.sizes["config.json"], expectedHash: manifest.hashes["config.json"])
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("config.json"))) as? [String: Any] ?? [:]
        guard let type = config["model_type"] as? String, ["llama", "mistral", "qwen2", "qwen3"].contains(type),
              config["quantization"] == nil, config["quantization_config"] == nil else {
            throw ModelControlError("Streaming currently supports unquantized dense Llama, classic Mistral, Qwen2, and Qwen3. For other architectures, import the checkpoint and use local quantization.")
        }
        for file in manifest.files where file != "config.json" && !file.hasSuffix(".safetensors") && !file.hasSuffix(".safetensors.index.json") {
            try Task.checkCancellation()
            update("Downloading model metadata: \(file)")
            try await hub.download(repository: repo, commit: manifest.commit, file: file, into: output,
                                   expectedSize: manifest.sizes[file], expectedHash: manifest.hashes[file])
        }
        let shards = manifest.files.filter { $0.hasSuffix(".safetensors") }
        if let largest = shards.compactMap({ manifest.sizes[$0] }).max() {
            update("Streaming \(shards.count) shard(s). Largest source shard: \(ByteCountFormatter.string(fromByteCount: largest, countStyle: .file)). Disk use includes the growing Q4 output plus one temporary source shard.")
        }
        var weightMap: [String: String] = [:]
        var quantization: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
        var seen = Set<String>()
        var expected = Set<String>()
        var totalSize = 0
        for (index, file) in shards.enumerated() {
            try Task.checkCancellation()
            if let bytes = manifest.sizes[file], bytes > 0, bytes < 1_125_899_906_842_624,
               let available = try? library.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               available < bytes + bytes / 2 + 128 * 1024 * 1024 {
                throw ModelControlError("Not enough free disk space for the next source shard and its quantized output. Free space or choose a model with smaller source shards.")
            }
            update("Downloading source shard \(index + 1)/\(shards.count): \(file)")
            try await hub.download(repository: repo, commit: manifest.commit, file: file, into: source,
                                   expectedSize: manifest.sizes[file], expectedHash: manifest.hashes[file])
            try Task.checkCancellation()
            let name = String(format: "model-%05d-of-%05d.safetensors", index + 1, shards.count)
            let target = output.appendingPathComponent(name)
            child = try launcher(.init(executableURL: trainer, arguments: ["quantize-shard", "--config", source.appendingPathComponent("config.json").path,
                "--shard", source.appendingPathComponent(file).path, "--output", target.path, "--method", request.method ?? "scalesearch"],
                workingDirectory: workspace, instanceID: id))
            while child?.status() == .running {
                collectLogs()
                try await Task.sleep(for: .milliseconds(300))
            }
            collectLogs()
            guard case .exited(0) = child?.status() else { throw ModelControlError("Shard conversion failed. Review the job log. No incomplete checkpoint was published.") }
            child = nil
            let sidecar = target.appendingPathExtension("json")
            guard let info = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any],
                  let keys = info["keys"] as? [String], let sourceKeys = info["sourceKeys"] as? [String],
                  let expectedKeys = info["expectedKeys"] as? [String], let decisions = info["quantization"] as? [String: Any],
                  let size = info["totalSize"] as? Int else { throw ModelControlError("Worker produced an invalid shard manifest.") }
            guard seen.isDisjoint(with: Set(sourceKeys)), keys.allSatisfy({ weightMap[$0] == nil }) else { throw ModelControlError("Checkpoint contains duplicate tensors across shards.") }
            seen.formUnion(sourceKeys)
            expected.formUnion(expectedKeys)
            for key in keys { weightMap[key] = name }
            quantization.merge(decisions) { _, new in new }
            totalSize += size
            try FileManager.default.removeItem(at: sidecar)
            try FileManager.default.removeItem(at: source.appendingPathComponent(file))
            update("Saved Q4 shard \(index + 1)/\(shards.count); deleted its temporary source shard.")
        }
        guard seen == expected else { throw ModelControlError("Source shards do not contain the complete expected model tensors. No checkpoint was published.") }
        try Task.checkCancellation()
        config["quantization"] = quantization
        config["quantization_config"] = quantization
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: ["metadata": ["total_size": totalSize], "weight_map": weightMap], options: [.sortedKeys])
            .write(to: output.appendingPathComponent("model.safetensors.index.json"))
        try JSONEncoder().encode(manifest).write(to: output.appendingPathComponent("studio-source.json"))
        try JSONEncoder().encode(request).write(to: output.appendingPathComponent("studio-quantization.json"))
        let published = library.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--") + "-q4-" + id.prefix(8))
        try FileManager.default.moveItem(at: output, to: published)
        return published
    }
    private func collectLogs() { for line in child?.drainLogs() ?? [] { update(line) } }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("jobs.json"), options: .atomic)
        try JSONEncoder().encode(datasets).write(to: directory.appendingPathComponent("datasets.json"), options: .atomic)
    }
}
