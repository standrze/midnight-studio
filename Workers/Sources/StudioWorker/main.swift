import ArgumentParser
import Foundation
import MLX
import MLXNN
import MLXOptimizers
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import ModelRunnerCore
import ModelRunnerProtocol
import HuggingFace
import Tokenizers

@main
struct StudioWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "midnight-studio-worker",
        abstract: "Native workers for Midnight Studio.", subcommands: [Train.self, QuantizeShard.self])
}

private func guardMemory() throws {
    try MLXResourceGuard.apply(MLXResourceLimits.resolve(for: .metal,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory))
}

private func log(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

struct Train: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Train a LoRA adapter with a full-sequence next-token objective.")
    @Option var model: String
    @Option var data: String
    @Option var output: String
    @Option var mode = "finetune"
    @Option var iterations = 100
    @Option var learningRate: Float = 0.00001
    @Option var layers = 4
    @Option var rank = 8
    @Option var sequenceLength = 512

    mutating func validate() throws {
        guard ["finetune", "cpt"].contains(mode), (1...100000).contains(iterations),
              (1...128).contains(layers), [4,8,16,32,64].contains(rank),
              (32...2048).contains(sequenceLength), learningRate.isFinite,
              (0.0000001...0.001).contains(learningRate) else { throw ValidationError("Invalid training parameters.") }
        guard !FileManager.default.fileExists(atPath: output) else { throw ValidationError("Output must be a new adapter directory.") }
    }

    func run() async throws {
        try guardMemory()
        await LagunaModelRegistration.register()
        let train = try readSplit("train")
        let validation = try readSplit("valid")
        guard Set(train).isDisjoint(with: Set(validation)) else { throw ValidationError("Training and validation overlap.") }
        log("Loading the local model. LoRA capability and sequence lengths will be checked before training.")
        let container = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(directory: URL(fileURLWithPath: model)))
        let destination = URL(fileURLWithPath: output)
        try await container.perform { context in
            guard let adaptable = context.model as? LoRAModel, adaptable.loraLayers.count >= layers else {
                throw ValidationError("This model does not expose the requested number of LoRA layers.")
            }
            for (split, examples) in [("train", train), ("valid", validation)] {
                for (index, text) in examples.enumerated() {
                    let count = context.tokenizer.encode(text: text).count
                    guard (2...sequenceLength).contains(count) else {
                        throw ValidationError("\(split) example \(index + 1) has \(count) tokens; split or shorten it to 2–\(sequenceLength). No examples are silently truncated.")
                    }
                }
            }
            let configuration = LoRAConfiguration(numLayers: layers, loraParameters: .init(rank: rank, scale: 16))
            _ = try LoRAContainer.from(model: context.model, configuration: configuration)
            guard !context.model.trainableParameters().flattened().isEmpty else { throw ValidationError("No trainable adapter parameters were created.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try JSONEncoder().encode(configuration).write(to: destination.appendingPathComponent("adapter_config.json"))
            let weights = destination.appendingPathComponent("adapters.safetensors")
            var invalidLoss = false
            log("Training \(mode): \(iterations) steps, batch 1, rank \(rank), \(layers) layers. Loss covers every non-padding next token.")
            try LoRATrain.train(model: context.model, train: train, validate: validation,
                optimizer: Adam(learningRate: learningRate), loss: Self.maskedLoss,
                tokenizer: context.tokenizer,
                parameters: .init(batchSize: 1, iterations: iterations, stepsPerReport: 1,
                    stepsPerEval: min(25, iterations), validationBatches: 0,
                    saveEvery: min(100, iterations), adapterURL: weights)) { progress in
                    log(progress.description)
                    switch progress {
                    case .train(_, let loss, _, _), .validation(_, let loss, _): invalidLoss = !loss.isFinite
                    default: break
                    }
                    return invalidLoss ? .stop : .more
                }
            guard !invalidLoss else { throw ValidationError("Training produced non-finite loss. The adapter is not complete.") }
            try LoRATrain.saveLoRAWeights(model: context.model, url: weights)
            let manifest: [String: Any] = ["status": "completed", "mode": mode, "baseModel": model,
                "iterations": iterations, "learningRate": learningRate, "sequenceLength": sequenceLength,
                "objective": "full-sequence next-token cross-entropy", "adaptation": "LoRA",
                "trainingExamples": train.count, "validationExamples": validation.count]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("studio-training.json"), options: .atomic)
            log("Adapter complete. Load with Midnight --model BASE --adapter \(destination.path)")
        }
    }

    private func readSplit(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: data).appendingPathComponent("\(name).jsonl")
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw ValidationError("Dataset split exceeds 2 MiB.") }
        struct Row: Decodable { let text: String }
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard !lines.isEmpty, lines.count <= 10000 else { throw ValidationError("Each split needs 1–10,000 examples.") }
        let examples = try lines.map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)).text }
        guard Set(examples).count == examples.count else { throw ValidationError("Remove duplicate examples.") }
        return examples
    }

    static func maskedLoss(model: Module, inputs: MLXArray, targets: MLXArray, lengths: MLXArray) -> (MLXArray, MLXArray) {
        let model = model as! any LanguageModel
        let logits = model(inputs, cache: nil).asType(.float32)
        // There are length - 1 next-token targets, not length targets.
        let mask = MLXArray(0..<inputs.dim(1))[.newAxis, 0...] .< (lengths - 1)[0..., .newAxis]
        let count = mask.sum()
        return ((crossEntropy(logits: logits, targets: targets) * mask).sum() / count, count)
    }
}

struct QuantizeShard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quantize one independent dense-model shard; Studio assembles the final checkpoint.")
    @Option var config: String
    @Option var shard: String
    @Option var output: String
    @Option var method = "scalesearch"

    func run() async throws {
        try guardMemory()
        guard ["scalesearch", "standard"].contains(method) else { throw ValidationError("Unknown quantization method.") }
        let configData = try Data(contentsOf: URL(fileURLWithPath: config))
        guard let object = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let type = object["model_type"] as? String, ["llama", "mistral", "qwen2", "qwen3"].contains(type),
              object["quantization"] == nil, object["quantization_config"] == nil else {
            throw ValidationError("Shard streaming currently supports unquantized dense Llama, classic Mistral, Qwen2, and Qwen3 checkpoints.")
        }
        let model = try await LLMTypeRegistry.shared.createModel(configuration: configData, modelType: type)
        let modules = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
        let weights = model.sanitize(weights: try MLX.loadArrays(url: URL(fileURLWithPath: shard)))
        var converted: [String: MLXArray] = [:]
        var decisions: [String: Any] = [:]
        for (key, weight) in weights.sorted(by: { $0.key < $1.key }) {
            guard expected[key] == weight.shape else { throw ValidationError("Unexpected tensor or shape: \(key). Use the full-checkpoint converter for this model.") }
            let path = key.hasSuffix(".weight") ? String(key.dropLast(7)) : ""
            if let module = modules[path], module is Linear || module is Embedding {
                guard weight.ndim == 2, weight.dim(-1) % 64 == 0 else {
                    converted[key] = weight; decisions[path] = false; continue
                }
                let (packed, scales, biases) = method == "scalesearch" && module is Linear
                    ? q4AffineScaleSearchQuantized(weight)
                    : MLX.quantized(weight, groupSize: 64, bits: 4, mode: .affine)
                converted[key] = packed
                converted[path + ".scales"] = scales
                converted[path + ".biases"] = biases
                eval(packed, scales)
                if let biases { eval(biases) }
                decisions[path] = ["bits": 4, "group_size": 64, "mode": "affine"]
                log("Quantized \(key)")
            } else { converted[key] = weight }
        }
        let destination = URL(fileURLWithPath: output)
        guard !FileManager.default.fileExists(atPath: output) else { throw ValidationError("Shard output already exists.") }
        try MLX.save(arrays: converted, metadata: ["format": "mlx"], url: destination)
        let metadata: [String: Any] = ["keys": converted.keys.sorted(), "sourceKeys": weights.keys.sorted(),
            "expectedKeys": expected.keys.sorted(), "quantization": decisions,
            "totalSize": converted.values.reduce(0) { $0 + $1.nbytes }]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            .write(to: destination.appendingPathExtension("json"), options: .atomic)
        log("Shard saved; its temporary source can now be deleted.")
    }
}
