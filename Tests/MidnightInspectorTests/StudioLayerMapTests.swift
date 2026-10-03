import Foundation
import Testing

@testable import MidnightInspector

struct StudioLayerMapTests {
    @Test func componentSizesUseOneScaleAndKeepActualIndices() throws {
        let object: [String: Any] = [
            "id": "fixture", "layerCount": 2,
            "layers": [
                layer(4, attention: 64, feedForward: 128), layer(9, attention: 32, feedForward: 64),
            ],
        ]
        let rows = try #require(StudioLayerMap.rows(object: object, width: 80))
        let text = rows.map(\.text).joined(separator: "\n")
        #expect(text.contains("L04") && text.contains("L09") && !text.contains("L00"))
        let bars = rows.filter { $0.text.hasPrefix("L") }
        let attention = bars.map { $0.segments.first { $0.tone == .attention }!.text }
        #expect(attention[0].count == attention[1].count * 2)
        #expect(text.components(separatedBy: "Attention").count == 2)
        #expect(text.contains("192 B") && text.contains("96 B"))
    }

    @Test func playbackChangesBrightnessWithoutChangingSize() throws {
        let object: [String: Any] = [
            "id": "fixture", "layerCount": 1, "layers": [layer(4, attention: 64, feedForward: 128)],
        ]
        let dim = try #require(StudioLayerMap.rows(object: object, width: 80, illumination: [4: 0.2]))
        let bright = try #require(StudioLayerMap.rows(object: object, width: 80, illumination: [4: 1]))
        #expect(dim.map(\.text) == bright.map(\.text))
        let structure = try #require(StudioLayerMap.rows(object: object, width: 80))
        let structureBars = structure.filter { $0.text.hasPrefix("L") }.flatMap(\.segments)
        let litBars = bright.filter { $0.text.hasPrefix("L") }.flatMap(\.segments)
        #expect(
            structureBars.filter { $0.tone == .attention }.map(\.text)
                == litBars.filter { $0.tone == .attention }.map(\.text))
        #expect(dim.flatMap(\.segments).filter { $0.intensity != nil }.allSatisfy { $0.intensity == 0.2 })
        #expect(bright.flatMap(\.segments).filter { $0.intensity != nil }.allSatisfy { $0.intensity == 1 })
    }

    @Test func componentOutputsIlluminateIndependentlyAndExpertsHaveIDs() throws {
        let object: [String: Any] = [
            "id": "fixture", "layerCount": 1,
            "layers": [layer(4, attention: 64, feedForward: 128)],
        ]
        let rows = try #require(
            StudioLayerMap.rows(
                object: object, width: 80,
                illumination: [4: 1], componentIllumination: [4: ["attention_output": 0, "feed_forward_output": 0.7]],
                routedExperts: [4: .init(tokenIndex: 3, expertIDs: [2, 9], weights: [0.75, 0.25])]))
        let bar = try #require(rows.first { $0.text.hasPrefix("L04") })
        #expect(bar.segments.first { $0.tone == .attention }?.intensity == 0)
        #expect(bar.segments.first { $0.tone == .feedForward }?.intensity == 0.7)
        let text = rows.map(\.text).joined(separator: "\n")
        #expect(text.contains("E002 ██ 0.75") && text.contains("E009 ██ 0.25"))
        #expect(!text.contains("E001"))
        #expect(text.contains("tensor storage"))
    }

    @Test func missingSizesAreVisibleAndPartialBlocksAreBounded() throws {
        let rows = try #require(StudioLayerMap.rows(object: ["layerCount": 1, "layers": [["index": 4]]], width: 32))
        #expect(rows.map(\.text).joined().contains("size unavailable"))
        #expect(StudioLayerMap.blocks(bytes: 1, scale: 16) == "▏  ")
        #expect(StudioLayerMap.blocks(bytes: 16, scale: 16) == "██ ")
        #expect(StudioLayerMap.blocks(bytes: 0, scale: 16).isEmpty)
    }

    @Test func malformedOrEmptyTopologyDoesNotInventLayers() {
        #expect(StudioLayerMap.rows(object: ["layerCount": 3, "layers": []], width: 80) == nil)
        #expect(
            StudioLayerMap.rows(object: ["layerCount": 0, "layers": []], width: 80)?.map(\.text) == [
                "No transformer layers were found."
            ])
    }

    private func layer(_ index: Int, attention: Int, feedForward: Int) -> [String: Any] {
        [
            "index": index, "weightBytes": attention + feedForward,
            "modules": [
                module("model.layers.\(index).self_attn.q_proj", bytes: attention),
                module("model.layers.\(index).mlp.up_proj", bytes: feedForward),
            ],
        ]
    }

    private func module(_ path: String, bytes: Int) -> [String: Any] {
        [
            "kind": "QuantizedLinear", "path": path,
            "parameters": [
                ["name": "weight", "shape": [bytes / 4], "dtype": "uint32"]
            ],
        ]
    }
}
