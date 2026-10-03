import Foundation
import Testing

@testable import MidnightInspector

struct StudioLayerMetricsTests {
    @Test func packedQuantizedTensorsIncludeScalesAndBiasesOnce() throws {
        let parameters = [
            tensor("weight", shape: [16, 4], dtype: "uint32"),
            tensor("scales", shape: [16, 1], dtype: "bfloat16"),
            tensor("biases", shape: [16, 1], dtype: "bfloat16"),
        ]
        var packed = module("self_attn.q_proj", parameters: parameters)
        packed["quantization"] = ["bits": 4, "groupSize": 32, "format": "affine"]
        let metrics = try #require(StudioLayerMetrics.decode(layer: layer([packed], total: 320)))
        #expect(metrics.index == 4)
        #expect(metrics.totalBytes == 320)
        #expect(metrics.storedBytes == 320)
        #expect(metrics.components.count == 1)
        #expect(metrics.components[0].family == .attention)
        #expect(metrics.components[0].bytes == 320)
    }

    @Test func expertAndNormalizationPathsTakePriorityOverParentFamilies() throws {
        let modules = [
            module("mlp.switch_mlp.up_proj"), module("mlp.shared_expert.down_proj"),
            module("mlp.experts.0.up_proj"), module("mlp.gate"), module("router"),
            module("mlp.gate_proj"), module("self_attn.q_norm"), module("mixer.conv1d"),
        ]
        let metrics = try #require(StudioLayerMetrics.decode(layer: layer(modules)))
        #expect(metrics.components.first { $0.family == .experts }?.bytes == 8)
        #expect(metrics.components.first { $0.family == .feedForward }?.bytes == 8)
        #expect(metrics.components.first { $0.family == .other }?.bytes == 12)
        #expect(metrics.components.first { $0.family == .convolution }?.bytes == 4)
        #expect(!metrics.components.contains { $0.family == .attention })
    }

    @Test func parentOwnedRemainderStaysVisibleAsOther() throws {
        let metrics = try #require(StudioLayerMetrics.decode(layer: layer([module("mlp.up_proj")], total: 12)))
        #expect(metrics.components.first { $0.family == .feedForward }?.bytes == 4)
        #expect(metrics.components.first { $0.family == .other }?.bytes == 8)
        #expect(metrics.storedBytes == 12)
        #expect(StudioLayerMetrics.decode(layer: layer([module("mlp.up_proj")], total: 3)) == nil)
    }

    @Test func missingLayerTotalDoesNotInventAReportedValue() throws {
        let metrics = try #require(StudioLayerMetrics.decode(layer: layer([module("mlp.up_proj")])))
        #expect(metrics.totalBytes == nil)
        #expect(metrics.storedBytes == 4)
    }

    @Test func scalarAndEmptyTensorsHaveTheirActualStorageSize() throws {
        let parameters = [
            tensor("scalar", shape: [], dtype: "complex64"),
            tensor("empty", shape: [Int.max, 0, Int.max], dtype: "float64"),
        ]
        let metrics = try #require(
            StudioLayerMetrics.decode(layer: layer([module("other", parameters: parameters)])))
        #expect(metrics.storedBytes == 8)
        let empty = try #require(StudioLayerMetrics.decode(layer: layer([module("other", parameters: [])], total: 0)))
        #expect(empty.storedBytes == 0)
    }

    @Test func unknownAndInvalidTensorMetadataDoesNotBecomeZero() {
        let invalid: [[String: Any]] = [
            ["name": "weight", "dtype": "float32"],
            tensor("weight", shape: [2], dtype: "float8"),
            tensor("weight", shape: [-1], dtype: "float32"),
            tensor("weight", shape: [1.5], dtype: "float32"),
            tensor("weight", shape: [true], dtype: "float32"),
            tensor("weight", shape: [Int.max, 2], dtype: "float32"),
        ]
        for parameter in invalid {
            #expect(StudioLayerMetrics.decode(layer: layer([module("mlp.up_proj", parameters: [parameter])])) == nil)
        }
        #expect(StudioLayerMetrics.decode(layer: ["index": 1, "modules": [["path": "mlp", "kind": "MLP"]]]) == nil)
    }

    @Test func duplicateModulesOrTensorNamesCannotDoubleCount() {
        let repeated = module("mlp.up_proj")
        #expect(StudioLayerMetrics.decode(layer: layer([repeated, repeated])) == nil)
        let parameter = tensor("weight", shape: [1], dtype: "float32")
        #expect(
            StudioLayerMetrics.decode(layer: layer([module("mlp.up_proj", parameters: [parameter, parameter])])) == nil)
    }

    @Test func invalidReportedTotalsAndSummationOverflowAreRejected() {
        for value: Any in [-1, 1.5, true, "12", NSNumber(value: UInt64.max)] {
            var input = layer([module("mlp.up_proj")])
            input["weightBytes"] = value
            #expect(StudioLayerMetrics.decode(layer: input) == nil)
        }
        let giant = tensor("weight", shape: [Int.max], dtype: "uint8")
        #expect(
            StudioLayerMetrics.decode(
                layer: layer([module("mlp.up_proj", parameters: [giant]), module("mlp.down_proj")])) == nil)
    }

    private func layer(_ modules: [[String: Any]], total: Int? = nil) -> [String: Any] {
        var result: [String: Any] = ["index": 4, "modules": modules]
        if let total { result["weightBytes"] = total }
        return result
    }

    private func module(_ path: String, parameters: [[String: Any]]? = nil) -> [String: Any] {
        [
            "path": "model.layers.4." + path, "kind": "Linear",
            "parameters": parameters ?? [tensor("weight", shape: [1], dtype: "float32")],
        ]
    }

    private func tensor(_ name: String, shape: [Any], dtype: String) -> [String: Any] {
        ["name": name, "shape": shape, "dtype": dtype]
    }
}
