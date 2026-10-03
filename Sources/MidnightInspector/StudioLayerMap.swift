import Foundation

/// Capacity bars use tensor storage; component output RMS and labelled router tiles show activity.
struct StudioLayerMap {
    private typealias Family = StudioLayerMetrics.Family

    static func rows(
        object: Any, width: Int, roomier: Bool = true, illumination: [Int: Double]? = nil,
        magnitudes: [Int: Double] = [:], componentIllumination: [Int: [String: Double]]? = nil,
        routedExperts: [Int: StudioActivationCapture.RoutingSample] = [:]
    ) -> [StudioInspectionRow]? {
        guard let model = object as? [String: Any],
            let source = model["layers"] as? [[String: Any]], source.count <= 1024,
            let count = model["layerCount"] as? Int, count == source.count
        else { return nil }
        guard !source.isEmpty else { return ["No transformer layers were found."] }
        guard source.allSatisfy({ $0["index"] is Int }) else { return nil }
        let metrics = source.map { StudioLayerMetrics.decode(layer: $0) }
        let maximum = metrics.compactMap { $0?.storedBytes }.max() ?? 0
        let showValues = width >= 64
        let reserved = showValues ? 36 : 10
        let blockLimit = max(5, min(24, (width - reserved) / 3))
        let scale = pow(2, ceil(log2(max(1, Double(maximum) / Double(max(1, blockLimit - 4))))))
        let families = Family.allCases.filter { family in
            metrics.contains { $0?.components.contains { $0.family == family && $0.bytes > 0 } == true }
        }
        var result: [StudioInspectionRow] = [
            .init(model["id"] as? String ?? "Loaded model", tone: .heading),
            .init("\(count) LAYERS  /  STORED WEIGHTS", tone: .muted),
            "",
        ]
        result += legend(families, width: width)
        result.append(.init("██ = \(formatBytes(scale)) · partial blocks rounded", tone: .muted))
        if componentIllumination != nil {
            result.append(
                .init("Expert ID tiles = selected routes · weights are normalized router weights", tone: .muted))
        }
        result.append("")

        let bars: [[StudioInspectionRow.Segment]] = metrics.map { metric in
            guard let metric else { return [.init(text: "size unavailable", tone: .muted)] }
            let intensity = illumination.map { $0[metric.index] ?? 0 }
            return metric.components.filter { $0.bytes > 0 }.map { component in
                let measured: Double?
                if let values = componentIllumination {
                    switch component.family {
                    case .attention: measured = values[metric.index]?["attention_output"] ?? 0
                    case .feedForward:
                        measured =
                            values[metric.index]?["feed_forward_output"]
                            ?? values[metric.index]?["shared_expert_output"] ?? 0
                    default: measured = 0
                    }
                } else {
                    measured = intensity
                }
                return .init(
                    text: blocks(bytes: component.bytes, scale: scale), tone: tone(component.family),
                    intensity: measured)
            }
        }
        let barWidth = bars.map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
        for (position, layer) in source.enumerated() {
            let index = layer["index"] as? Int ?? position
            let label = String(format: "L%02d", index)
            var row: [StudioInspectionRow.Segment] = [
                .init(text: label + String(repeating: " ", count: max(1, 5 - label.count)), tone: .spine)
            ]
            row += bars[position]
            let used = bars[position].reduce(0) { $0 + $1.text.count }
            row.append(.init(text: String(repeating: " ", count: max(0, barWidth - used)), tone: .text))
            if showValues, let metric = metrics[position] {
                row.append(.init(text: " \(formatBytes(Double(metric.storedBytes)))", tone: .muted))
                if metric.storedBytes == 0 { row.append(.init(text: " (empty)", tone: .muted)) }
            }
            if showValues, illumination != nil, componentIllumination == nil {
                let value = magnitudes[index].map { String(format: "%.3f", $0) } ?? "—"
                row.append(.init(text: "  RMS \(value)", tone: .muted))
            }
            result.append(.init(segments: row))
            if let selected = routedExperts[index] {
                var tiles: [StudioInspectionRow.Segment] = [.init(text: "     ", tone: .spine)]
                var used = 5
                for (expert, weight) in zip(selected.expertIDs, selected.weights) {
                    let label = String(format: "E%03d ██ %.2f  ", expert, weight)
                    if used + label.count > max(20, width), tiles.count > 1 {
                        result.append(.init(segments: tiles))
                        tiles = [.init(text: "     ", tone: .spine)]
                        used = 5
                    }
                    tiles.append(.init(text: label, tone: .experts, intensity: 1))
                    used += label.count
                }
                result.append(.init(segments: tiles))
            }
            if roomier { result.append("") }
        }
        result.append("")
        result.append(.init("Block length = tensor storage · not parameter count or activation", tone: .muted))
        return result
    }

    /// Two terminal cells form one full block; spaces keep adjacent blocks distinct.
    static func blocks(bytes: Int, scale: Double) -> String {
        guard bytes > 0, scale.isFinite, scale >= 1 else { return "" }
        let units = Double(bytes) / scale
        let whole = min(24, Int(min(24, floor(units))))
        var result = String(repeating: "██ ", count: whole)
        let remainder = units - Double(whole)
        if remainder > 0, whole < 24 {
            let fill = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]
            let steps = max(1, min(16, Int((remainder * 16).rounded())))
            result += fill[min(8, steps)] + fill[max(0, steps - 8)] + " "
        }
        return result
    }

    private static func formatBytes(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MiB", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.1f KiB", bytes / 1024) }
        return String(format: "%.0f B", bytes)
    }

    private static func tone(_ family: Family) -> StudioInspectionRow.Tone {
        switch family {
        case .attention: .attention
        case .convolution: .convolution
        case .experts: .experts
        case .feedForward: .feedForward
        case .other: .muted
        }
    }

    private static func label(_ family: Family) -> String {
        switch family {
        case .attention: "Attention"
        case .convolution: "Convolution"
        case .experts: "Experts / MoE"
        case .feedForward: "Feed-forward / shared"
        case .other: "Router / norm / other"
        }
    }

    private static func legend(_ families: [Family], width: Int) -> [StudioInspectionRow] {
        var rows: [StudioInspectionRow] = []
        var segments: [StudioInspectionRow.Segment] = []
        var used = 0
        for family in families {
            let title = label(family)
            let length = title.count + 6
            if used > 0, used + length > max(1, width) {
                rows.append(.init(segments: segments))
                segments = []
                used = 0
            }
            segments.append(.init(text: "██", tone: tone(family)))
            segments.append(.init(text: " \(title)   ", tone: .muted))
            used += length
        }
        if !segments.isEmpty { rows.append(.init(segments: segments)) }
        return rows
    }
}
