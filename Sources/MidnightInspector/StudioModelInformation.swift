import Foundation

/// Model metadata and allocator/throughput observations from one serving generation.
struct StudioModelInformation: Sendable {
    let modelData: Data?
    let runtimeData: Data?
    let notes: [String]
    let updatedAt: Date

    private static func object(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var generation: UInt64? { (Self.object(runtimeData)["modelGeneration"] as? NSNumber)?.uint64Value }
    var modelID: String? { Self.object(modelData)["id"] as? String }

    func rows(width: Int) -> [StudioInspectionRow] {
        let model = Self.object(modelData)
        let runtime = Self.object(runtimeData)
        let loaded = runtime["loadedModel"] as? [String: Any] ?? [:]
        let card = model["modelCard"] as? [String: Any] ?? loaded["model_card"] as? [String: Any] ?? [:]
        let memory = runtime["memory"] as? [String: Any] ?? [:]
        let metrics = runtime["generationMetrics"] as? [String: Any] ?? [:]
        let layers = model["layers"] as? [[String: Any]] ?? []
        let modules = layers.flatMap { $0["modules"] as? [[String: Any]] ?? [] }
        var rows: [StudioInspectionRow] = [.init("MODEL INFORMATION", tone: .heading), ""]
        func value(_ label: String, _ text: String?) {
            rows.append(
                .init(segments: [
                    .init(text: label.padding(toLength: 22, withPad: " ", startingAt: 0), tone: .muted),
                    .init(text: text ?? "Not reported", tone: .text),
                ]))
        }
        func integer(_ dictionary: [String: Any], _ key: String) -> String? {
            guard let number = dictionary[key] as? NSNumber, number.doubleValue.isFinite,
                number.doubleValue >= 0
            else { return nil }
            return number.stringValue
        }
        func bytes(_ dictionary: [String: Any], _ key: String) -> String? {
            guard let number = dictionary[key] as? NSNumber,
                number.doubleValue.isFinite, number.doubleValue >= 0
            else { return nil }
            let size = number.doubleValue
            if size >= 1_073_741_824 { return String(format: "%.2f GiB", size / 1_073_741_824) }
            if size >= 1_048_576 { return String(format: "%.1f MiB", size / 1_048_576) }
            if size >= 1024 { return String(format: "%.1f KiB", size / 1024) }
            return String(format: "%.0f B", size)
        }
        func rate(_ key: String) -> String? {
            guard let number = metrics[key] as? NSNumber,
                number.doubleValue.isFinite, number.doubleValue >= 0
            else { return nil }
            return String(format: "%.1f tok/s", number.doubleValue)
        }
        value("Name", card["name"] as? String ?? model["id"] as? String ?? loaded["id"] as? String)
        value("Model ID", model["id"] as? String ?? loaded["id"] as? String)
        if let description = card["description"] as? String, !description.isEmpty {
            value("Description", String(description.prefix(max(24, width - 22))))
        }
        rows += ["", .init("ARCHITECTURE", tone: .spine)]
        value("Family", model["modelType"] as? String)
        value("Native runtime", model["runtimeType"] as? String)
        value("Transformer layers", integer(model, "layerCount"))
        value("Hidden width", integer(model, "hiddenSize"))
        value(
            "Attention / KV heads",
            [integer(model, "attentionHeads") ?? "—", integer(model, "kvHeads") ?? "—"].joined(separator: " / "))
        value(
            "Experts / per token",
            [integer(model, "expertCount") ?? "—", integer(model, "expertsPerToken") ?? "—"].joined(separator: " / "))
        value("Activation function", model["activation"] as? String)
        var patterns: [String: Int] = [:]
        for layer in layers {
            if let kind = layer["kind"] as? String { patterns[kind, default: 0] += 1 }
        }
        for kind in patterns.keys.sorted() { value("Layer layout", "\(patterns[kind]!) × \(kind)") }
        let quantizations = modules.compactMap { $0["quantization"] as? [String: Any] }.map {
            "\(integer($0, "bits") ?? "?")-bit \($0["format"] as? String ?? "unknown") · group \(integer($0, "groupSize") ?? "?")"
        }
        var formats: [String: Int] = [:]
        for format in quantizations { formats[format, default: 0] += 1 }
        if formats.isEmpty { value("Quantization", modules.isEmpty ? nil : "No quantized modules reported") }
        for format in formats.keys.sorted() { value("Quantization", "\(format) · \(formats[format]!) modules") }
        let dtypes = Set(
            modules.flatMap { $0["parameters"] as? [[String: Any]] ?? [] }.compactMap { $0["dtype"] as? String }
        ).sorted()
        if !dtypes.isEmpty { value("Stored tensor dtypes", dtypes.joined(separator: ", ")) }

        rows += ["", .init("MEMORY / VRAM", tone: .spine)]
        value("Stored model weights", bytes(model, "weightBytes"))
        value("Active MLX memory", bytes(memory, "activeBytes"))
        value("Cached MLX buffers", bytes(memory, "cachedBytes"))
        value("Peak MLX memory", bytes(memory, "peakBytes"))
        value("Configured budget", bytes(loaded, "memory_limit_bytes"))
        rows.append(.init("MLX allocator usage; excludes other process/system allocations.", tone: .muted))
        rows.append(.init("Apple Silicon uses unified memory. Dedicated VRAM total is not reported.", tone: .muted))

        rows += ["", .init("SERVING / LATEST GENERATION", tone: .spine)]
        value("Runtime phase", runtime["phase"] as? String)
        value("Decode throughput", rate("tokensPerSecond"))
        value("Prefill throughput", rate("promptTokensPerSecond"))
        value(
            "Prompt / cached",
            metrics.isEmpty
                ? nil
                : "\(integer(metrics, "promptTokenCount") ?? "—") / \(integer(metrics, "cachedPromptTokenCount") ?? "—") tokens"
        )
        value("Evaluated prompt", integer(metrics, "prefilledPromptTokenCount"))
        value("Generated tokens", integer(metrics, "generationTokenCount"))
        value("Stop reason", metrics["stopReason"] as? String)
        value("Active context limit", integer(model, "contextLength") ?? integer(loaded, "context_length"))
        value("Checkpoint context", integer(model, "configuredContextLength"))
        value("Prefill chunk size", integer(loaded, "prefill_step_size"))
        value("KV compression", loaded["kv_compression"] as? String)
        value(
            "Output default / max",
            "\(integer(loaded, "default_output_tokens") ?? "—") / \(integer(loaded, "max_output_tokens") ?? "—")")
        if metrics.isEmpty {
            rows.append(.init("Throughput appears after this model reports a completed generation.", tone: .muted))
        }

        rows += ["", .init("CAPABILITIES", tone: .spine)]
        if let supported = model["traceSupported"] as? Bool {
            value("Activation capture", supported ? "Supported" : model["traceReason"] as? String ?? "Unavailable")
        } else {
            value("Activation capture", nil)
        }
        let capabilities = card["capabilities"] as? [String: Any] ?? [:]
        let enabled = [
            ("vision", "Vision"), ("audio_input", "Audio input"), ("audio_output", "Audio output"),
            ("decisions", "Decisions"),
        ]
        .compactMap { key, label in capabilities[key] as? Bool == true ? label : nil }
        value(
            "Modalities / features",
            capabilities.isEmpty
                ? nil
                : ((loaded["modality"] as? String == "voice" ? ["Voice"] : ["Text"]) + enabled).joined(separator: " · ")
        )
        for note in notes { rows.append(.init(note, tone: .muted)) }
        rows += [
            "",
            .init(
                "Updated \(updatedAt.formatted(date: .omitted, time: .standard)) · runtime refresh every 2 seconds",
                tone: .muted),
        ]
        return rows
    }
}

extension StudioInspectionClient {
    /// Reuses architecture metadata only while the runtime's resident model generation matches.
    func modelInformation(
        previous: StudioModelInformation? = nil,
        routing: @Sendable () async -> ModelControlRoutingState
    ) async throws -> StudioModelInformation {
        let initial = await routing()
        var notes: [String] = []
        var runtime: Data?
        do { runtime = try await fetch(path: "v1/runtime", timeout: 5, routing: routing) } catch {
            try Task.checkCancellation()
            notes.append("Runtime information unavailable: \(error.localizedDescription)")
        }
        let runtimeObject = runtime.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let generation = (runtimeObject["modelGeneration"] as? NSNumber)?.uint64Value
        let loadedID = (runtimeObject["loadedModel"] as? [String: Any])?["id"] as? String
        var model: Data?
        if let generation, generation == previous?.generation, loadedID == previous?.modelID,
            let saved = previous?.modelData
        {
            model = saved
        } else {
            do { model = try await fetch(path: "v1/inspector/model", timeout: 8, routing: routing) } catch {
                try Task.checkCancellation()
                notes.append("Architecture information unavailable: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        guard await routing().revision == initial.revision else {
            throw ConfigurationError("The model connection changed during model information refresh.")
        }
        if let model, let object = try JSONSerialization.jsonObject(with: model) as? [String: Any] {
            let modelGeneration = (object["runtimeGeneration"] as? NSNumber)?.uint64Value
            if let generation, let modelGeneration, generation != modelGeneration {
                throw ConfigurationError("The resident model changed during inspection. Refresh model information.")
            }
            if let loadedID, let inspectedID = object["id"] as? String, loadedID != inspectedID {
                throw ConfigurationError(
                    "Runtime and architecture describe different models. Refresh model information.")
            }
        }
        guard runtime != nil || model != nil else { throw ConfigurationError(notes.joined(separator: " · ")) }
        return StudioModelInformation(modelData: model, runtimeData: runtime, notes: notes, updatedAt: Date())
    }
}
