import CoreFoundation
import Foundation

/// Stored tensor bytes grouped by module family.
///
/// These are checkpoint storage sizes, not logical parameter counts, activation measurements, or allocated GPU memory.
struct StudioLayerMetrics: Sendable {
    enum Family: CaseIterable, Sendable {
        case attention, convolution, experts, feedForward, other
    }

    struct Component: Sendable {
        let family: Family
        let bytes: Int
    }

    let index: Int
    /// The layer's reported weightBytes; absent when the snapshot does not report it.
    let totalBytes: Int?
    let components: [Component]

    /// The validated component sum, including any unattributed reported remainder.
    var storedBytes: Int { components.reduce(0) { $0 + $1.bytes } }

    /// Returns nil if incomplete or inconsistent tensor metadata prevents sizing.
    static func decode(layer: [String: Any]) -> StudioLayerMetrics? {
        guard let index = nonnegativeInteger(layer["index"]),
            let modules = layer["modules"] as? [[String: Any]], modules.count <= 2048
        else { return nil }

        let totalBytes: Int?
        if let reported = layer["weightBytes"] {
            guard let value = nonnegativeInteger(reported) else { return nil }
            totalBytes = value
        } else {
            totalBytes = nil
        }

        var bytesByFamily: [Family: Int] = [:]
        var paths = Set<String>()
        var sum = 0
        for module in modules {
            guard let path = module["path"] as? String, !path.isEmpty, paths.insert(path).inserted,
                let kind = module["kind"] as? String,
                let parameters = module["parameters"] as? [[String: Any]], parameters.count <= 256
            else { return nil }

            let family = family(path: path, kind: kind)
            var names = Set<String>()
            var moduleBytes = 0
            for parameter in parameters {
                guard let name = parameter["name"] as? String, names.insert(name).inserted,
                    let bytes = tensorBytes(parameter),
                    let next = adding(moduleBytes, bytes)
                else { return nil }
                moduleBytes = next
            }

            guard let familyBytes = adding(bytesByFamily[family, default: 0], moduleBytes),
                let nextSum = adding(sum, moduleBytes)
            else { return nil }
            bytesByFamily[family] = familyBytes
            sum = nextSum
        }

        if let totalBytes {
            guard sum <= totalBytes else { return nil }
            if sum < totalBytes {
                // Leaf modules can omit tensors owned directly by a parent module.
                bytesByFamily[.other, default: 0] += totalBytes - sum
            }
        }
        let components = Family.allCases.compactMap { family -> Component? in
            guard let bytes = bytesByFamily[family] else { return nil }
            return Component(family: family, bytes: bytes)
        }
        return StudioLayerMetrics(index: index, totalBytes: totalBytes, components: components)
    }

    private static func family(path: String, kind: String) -> Family {
        let path = path.lowercased()
        let kind = kind.lowercased()
        let parts = path.split(separator: ".").map(String.init)
        let hasRouter = parts.contains("router") || path.contains(".mlp.gate.") || path.hasSuffix(".mlp.gate")
        if hasRouter || kind.contains("router") { return .other }
        if path.contains("shared_expert") { return .feedForward }
        if path.contains("switch_mlp") || parts.contains("experts") || kind.contains("expert") {
            return .experts
        }
        if path.contains("norm") || kind.contains("norm") { return .other }
        if path.contains("conv") || kind.contains("conv") { return .convolution }
        if parts.contains("self_attn") || parts.contains("attn") || parts.contains("attention")
            || kind.contains("attention")
        {
            return .attention
        }
        if parts.contains("mlp") || path.contains("feed_forward") || path.contains("feedforward")
            || kind.contains("mlp") || kind.contains("feedforward") || kind.contains("feed_forward")
        {
            return .feedForward
        }
        return .other
    }

    private static func tensorBytes(_ parameter: [String: Any]) -> Int? {
        guard let dtype = parameter["dtype"] as? String,
            let shape = parameter["shape"] as? [Any], shape.count <= 16
        else { return nil }
        let itemBytes: Int
        switch dtype {
        case "bool", "uint8", "int8": itemBytes = 1
        case "uint16", "int16", "float16", "bfloat16": itemBytes = 2
        case "uint32", "int32", "float32": itemBytes = 4
        case "uint64", "int64", "float64", "complex64": itemBytes = 8
        default: return nil
        }

        var dimensions: [Int] = []
        for value in shape {
            guard let dimension = nonnegativeInteger(value) else { return nil }
            dimensions.append(dimension)
        }
        if dimensions.contains(0) { return 0 }
        var bytes = itemBytes
        for dimension in dimensions {
            let (product, overflow) = bytes.multipliedReportingOverflow(by: dimension)
            guard !overflow else { return nil }
            bytes = product
        }
        return bytes
    }

    private static func adding(_ first: Int, _ second: Int) -> Int? {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? nil : sum
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer: Int?
        switch String(cString: number.objCType) {
        case "f", "d": integer = Int(exactly: number.doubleValue)
        case "Q", "L", "I", "S", "C": integer = Int(exactly: number.uint64Value)
        default: integer = Int(exactly: number.int64Value)
        }
        guard let integer, integer >= 0 else { return nil }
        return integer
    }
}
