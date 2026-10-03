import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import XCTest
@testable import StudioWorker

final class StudioWorkerTests: XCTestCase {
    private let config = #"{"model_type":"llama","hidden_size":64,"head_dim":32,"intermediate_size":128,"num_hidden_layers":1,"num_attention_heads":2,"num_key_value_heads":2,"vocab_size":128,"rms_norm_eps":0.00001,"max_position_embeddings":128,"rope_theta":10000,"tie_word_embeddings":false,"bos_token_id":1,"eos_token_id":2}"#

    func testShardConversionMatchesFullConverterAndReloads() async throws {
        for modelType in ["llama", "mistral", "qwen2", "qwen3"] {
            try await Device.withDefaultDevice(.cpu) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-numeric-\(UUID().uuidString)")
                let source = root.appendingPathComponent("source")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let data = Data(config.replacingOccurrences(of: "llama", with: modelType).utf8)
                try data.write(to: source.appendingPathComponent("config.json"))
                let model = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: modelType)
                let weights = Dictionary(uniqueKeysWithValues: model.parameters().flattened()).mapValues { $0.asType(.bfloat16) }
                try MLX.save(arrays: weights, url: source.appendingPathComponent("model.safetensors"))
                for method in ["standard", "scalesearch"] {
                    let full = root.appendingPathComponent("full-\(method)")
                    _ = try await LLMModelFactory.shared.convert(from: source, to: full,
                        options: .init(bits: 4, groupSize: 64, mode: .affine, calibration: method == "standard" ? .standard : .q4AffineScaleSearch))
                    let streamed = root.appendingPathComponent("stream-\(method)")
                    try FileManager.default.createDirectory(at: streamed, withIntermediateDirectories: true)
                    let keys = weights.keys.sorted()
                    var actual: [String: MLXArray] = [:]
                    var policy: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
                    for index in 0..<2 {
                        let shard = root.appendingPathComponent("part-\(index).safetensors")
                        let subset = Dictionary(uniqueKeysWithValues: keys.enumerated().filter { $0.offset % 2 == index }.map { ($0.element, weights[$0.element]!) })
                        try MLX.save(arrays: subset, url: shard)
                        let output = streamed.appendingPathComponent("model-\(index).safetensors")
                        let command = try QuantizeShard.parse(["--config", source.appendingPathComponent("config.json").path, "--shard", shard.path, "--output", output.path, "--method", method])
                        try await command.run()
                        actual.merge(try MLX.loadArrays(url: output)) { _, new in new }
                        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathExtension("json"))) as? [String: Any])
                        policy.merge(try XCTUnwrap(metadata["quantization"] as? [String: Any])) { _, new in new }
                    }
                    var reference: [String: MLXArray] = [:]
                    for file in try FileManager.default.contentsOfDirectory(at: full, includingPropertiesForKeys: nil) where file.pathExtension == "safetensors" {
                        reference.merge(try MLX.loadArrays(url: file)) { _, new in new }
                    }
                    XCTAssertEqual(Set(reference.keys), Set(actual.keys))
                    for key in reference.keys {
                        XCTAssertTrue(MLX.all(reference[key]! .== actual[key]!).item(Bool.self), key)
                    }
                    var configObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    configObject["quantization"] = policy
                    let configData = try JSONSerialization.data(withJSONObject: configObject)
                    try configData.write(to: streamed.appendingPathComponent("config.json"))
                    let reloaded = try await LLMTypeRegistry.shared.createModel(configuration: configData, modelType: modelType)
                    let base = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
                    try loadWeights(modelDirectory: streamed, model: reloaded, quantization: base.quantization, perLayerQuantization: base.perLayerQuantization)
                    let logits = reloaded(MLXArray([1, 3, 4])[.newAxis, 0...], cache: nil)
                    XCTAssertTrue(MLX.all(MLX.isFinite(logits)).item(Bool.self))
                }
            }
    }
    }

    func testNativeTrainingWritesReloadableAdapter() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-train-\(UUID().uuidString)")
            let source = root.appendingPathComponent("base")
            let dataset = root.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let data = Data(config.utf8)
            try data.write(to: source.appendingPathComponent("config.json"))
            let model = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: "llama")
            try MLX.save(arrays: Dictionary(uniqueKeysWithValues: model.parameters().flattened()), url: source.appendingPathComponent("model.safetensors"))
            let tokenizer = #"{"version":"1.0","added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":{"type":"ByteLevel"},"model":{"type":"BPE","vocab":{"<unk>":0,"<s>":1,"</s>":2,"a":3,"b":4,"c":5,"d":6},"merges":[],"unk_token":"<unk>"}}"#
            try Data(tokenizer.utf8).write(to: source.appendingPathComponent("tokenizer.json"))
            try Data(#"{"tokenizer_class":"PreTrainedTokenizerFast","unk_token":"<unk>","bos_token":"<s>","eos_token":"</s>"}"#.utf8).write(to: source.appendingPathComponent("tokenizer_config.json"))
            try Data(#"{"text":"a b c"}"#.utf8).write(to: dataset.appendingPathComponent("train.jsonl"))
            try Data(#"{"text":"a b d"}"#.utf8).write(to: dataset.appendingPathComponent("valid.jsonl"))
            for mode in ["finetune", "cpt"] {
                let output = root.appendingPathComponent(mode)
                let command = try Train.parse(["--model", source.path, "--data", dataset.path, "--output", output.path,
                    "--mode", mode, "--iterations", "2", "--layers", "1", "--rank", "4", "--sequence-length", "32"])
                try await command.run()
                let adapter = try LoRAContainer.from(directory: output)
                let fresh = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: "llama")
                try loadWeights(modelDirectory: source, model: fresh)
                try adapter.load(into: fresh)
                let logits = fresh(MLXArray([1,3,4])[.newAxis,0...], cache:nil)
                XCTAssertTrue(MLX.all(MLX.isFinite(logits)).item(Bool.self))
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("studio-training.json").path))
            }
        }
    }
}
