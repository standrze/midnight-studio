import Foundation
import loom
import weft

/// Main-actor ownership serializes rendering and input; the manager owns its child process.
@MainActor
final class StudioTerminal {
    private let manager: ModelControlManager
    private var terminal: Terminal<ANSIBackend>?
    private var models: [ModelControlModel] = []
    private var state: ModelControlState?
    private var selected = 0
    private var message = "Select a model and press Enter to load."
    private var detail: [StudioInspectionRow] = []
    private var offset = 0
    private var operation: Task<Void, Never>?
    private let inspection = StudioInspectionClient()
    private var routingRevision: String?
    private var topologyData: Data?
    private var showingModelInformation = false
    private var modelInformation: StudioModelInformation?
    private var informationTask: Task<Void, Never>?
    private var informationStatus = ""
    private var nextInformationRefresh = Date.distantPast
    private var capture: StudioActivationCapture?
    private let recordingClient = StudioRecordingClient()
    private let recordingStore: StudioRecordingStore
    private var recordingActive = false
    private var recordingStatus: String?
    private var library: [StudioRecordingStore.Entry]?
    private var librarySelection = 0
    private var replayingSaved = false
    private var playbackCursor = 0
    private var playing = false
    private var playbackSite = "layer_input"

    init(manager: ModelControlManager, stateDirectory: URL) {
        self.manager = manager
        recordingStore = StudioRecordingStore(stateDirectory: stateDirectory)
    }

    func run() async throws {
        let session = try TerminalSession(options: TerminalOptions(alternateScreen: true, hideCursor: true))
        defer {
            informationTask?.cancel()
            terminal = nil
            session.close()
        }
        let events = TerminalEvents(session: session)
        defer { events.stop() }
        let size = TerminalSession.size()
        terminal = Terminal(backend: ANSIBackend(), width: size.width, height: size.height)
        try await refresh(catalog: true)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.consume(events) }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        await self.advancePlayback()
                        try await self.refresh(catalog: false)
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            operation?.cancel()
            await operation?.value
            informationTask?.cancel()
            await informationTask?.value
            throw error
        }
        operation?.cancel()
        await operation?.value
        informationTask?.cancel()
        await informationTask?.value
    }

    private func consume(_ events: TerminalEvents) async throws {
        for try await batch in events.events {
            try Task.checkCancellation()
            for event in batch {
                if case .signal = event { return }
                if case .resize(let width, let height) = event { terminal?.resize(width: width, height: height) }
                guard let keyboard = event.keyboardEvent, keyboard.kind != .release else { continue }
                if keyboard.key == .interrupt || keyboard.key == .endOfInput { return }
                switch keyboard.key {
                case .character("q"): return
                case .character("a"):
                    if recordingActive {
                        operation?.cancel()
                        message = "Stopping recording; the external chat continues."
                    } else {
                        record()
                    }
                case .character("m"): openModelInformation()
                case .character("l"): openLibrary()
                case .character(" "): togglePlayback()
                case .left: stepPlayback(-1)
                case .right: stepPlayback(1)
                case .character("v"): switchSite()
                case .up:
                    if showingModelInformation {
                        offset = max(0, offset - 1)
                    } else if library != nil {
                        librarySelection = max(0, librarySelection - 1)
                    } else if detail.isEmpty {
                        selected = max(0, selected - 1)
                    } else {
                        offset = max(0, offset - 1)
                    }
                case .down:
                    if showingModelInformation {
                        let count = modelInformation?.rows(width: TerminalSession.size().width - 2).count ?? 0
                        offset = min(max(0, count - 1), offset + 1)
                    } else if let library {
                        librarySelection = min(max(0, library.count - 1), librarySelection + 1)
                    } else if detail.isEmpty {
                        selected = min(max(0, models.count - 1), selected + 1)
                    } else {
                        offset = min(max(0, detail.count - 1), offset + 1)
                    }
                case .escape:
                    if showingModelInformation {
                        showingModelInformation = false
                        informationTask?.cancel()
                        offset = 0
                        message = "Returned from model information."
                    } else {
                        operation?.cancel()
                        clearInspection()
                    }
                case .enter:
                    guard !showingModelInformation else { break }
                    if library != nil {
                        loadLibrarySelection()
                    } else if detail.isEmpty, models.indices.contains(selected) {
                        do { state = try await manager.load(profile(for: models[selected])) } catch {
                            message = error.localizedDescription
                        }
                    }
                case .character("u"):
                    do { state = try await manager.unload() } catch { message = error.localizedDescription }
                case .character("e"):
                    do { state = try await manager.useExternal() } catch { message = error.localizedDescription }
                case .character("p"):
                    if models.indices.contains(selected) {
                        do {
                            state = try await manager.save(profile(for: models[selected]))
                            message = "Profile saved."
                        } catch { message = error.localizedDescription }
                    }
                case .character("i"):
                    if showingModelInformation, topologyData != nil {
                        showingModelInformation = false
                        library = nil
                        informationTask?.cancel()
                        offset = 0
                    } else {
                        inspect(path: "v1/inspector/model")
                    }
                case .character("s"): inspect(path: "v1/runtime")
                case .character("r"):
                    nextInformationRefresh = .distantPast
                    try await refresh(catalog: true)
                default: break
                }
            }
            try draw()
        }
    }

    private func profile(for model: ModelControlModel) -> ModelControlProfile {
        state?.savedProfiles.first(where: { $0.modelID == model.id }) ?? model.defaults
    }

    private func refresh(catalog: Bool) async throws {
        state = await manager.state()
        let route = await manager.routingState()
        if let previous = routingRevision, previous != route.revision {
            operation?.cancel()
            if !replayingSaved, library == nil {
                clearInspection()
                message = "Model connection changed. Press i to inspect its current topology."
            }
        }
        routingRevision = route.revision
        if catalog {
            let id = models.indices.contains(selected) ? models[selected].id : nil
            models = await manager.catalog()
            selected = models.firstIndex(where: { $0.id == id }) ?? 0
        }
        refreshModelInformationIfNeeded()
        let size = TerminalSession.size()
        terminal?.resize(width: size.width, height: size.height)
        try draw()
    }

    private func inspect(path: String) {
        guard operation == nil else {
            message = "An inspection request is already running."
            return
        }
        clearInspection()
        let width = max(1, TerminalSession.size().width - 2)
        message = "Reading Midnight…"
        operation = Task {
            defer { operation = nil }
            do {
                if path == "v1/inspector/model" {
                    let data = try await inspection.fetch(path: path) { await self.manager.routingState() }
                    try Task.checkCancellation()
                    topologyData = data
                    rebuildTopology(width: width)
                } else {
                    let rows = try await inspection.read(path: path, width: width) { await self.manager.routingState() }
                    try Task.checkCancellation()
                    detail = rows
                }
                offset = 0
                message = "Press a to record the next chat from OnoSendai or another connected client."
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func openModelInformation() {
        showingModelInformation = true
        playing = false
        offset = 0
        nextInformationRefresh = .distantPast
        refreshModelInformationIfNeeded()
    }

    private func refreshModelInformationIfNeeded() {
        guard showingModelInformation, informationTask == nil, Date() >= nextInformationRefresh else { return }
        nextInformationRefresh = Date().addingTimeInterval(2)
        informationStatus = modelInformation == nil ? "Reading model and runtime information…" : "Refreshing runtime…"
        informationTask = Task {
            defer { informationTask = nil }
            do {
                let snapshot = try await inspection.modelInformation(previous: modelInformation) {
                    await self.manager.routingState()
                }
                try Task.checkCancellation()
                guard showingModelInformation else { return }
                modelInformation = snapshot
                informationStatus = "m model info · i layers · r refresh · Esc back"
            } catch {
                if !Task.isCancelled, showingModelInformation {
                    informationStatus = "Refresh failed; previous snapshot retained. \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearInspection() {
        showingModelInformation = false
        informationTask?.cancel()
        modelInformation = nil
        detail = []
        topologyData = nil
        capture = nil
        library = nil
        replayingSaved = false
        playing = false
        playbackCursor = 0
        offset = 0
    }

    private func record() {
        guard operation == nil else {
            message = "Wait for the current request, or press Esc to cancel."
            return
        }
        library = nil
        replayingSaved = false
        capture = nil
        playing = false
        recordingActive = true
        recordingStatus = "ARMING"
        message = "Arming the next chat recording…"
        operation = Task {
            defer {
                operation = nil
                recordingActive = false
                recordingStatus = nil
            }
            var armed: StudioRecordingClient.Armed?
            let attemptID = UUID().uuidString
            var loggedStatus = "armed"
            do {
                let client = recordingClient
                let manager = manager
                // Let the short arm finish so cancellation always has its session ID.
                let handle = try await Task {
                    try await client.arm { await manager.routingState() }
                }.value
                armed = handle
                try await recordingStore.log(id: handle.id, model: handle.selection.model, status: "armed")
                try Task.checkCancellation()
                topologyData = handle.topology
                recordingStatus = "ARMED · WAITING FOR CHAT"
                message = "Send a message from OnoSendai or your chat app to this Midnight server. a stops recording."
                while true {
                    let update = try await client.poll(handle) { await manager.routingState() }
                    if update.status != loggedStatus, update.status != "completed" {
                        try await recordingStore.log(
                            id: handle.id, model: handle.selection.model, status: update.status)
                        loggedStatus = update.status
                    }
                    if let recorded = update.capture {
                        armed = nil
                        applyCapture(recorded)
                        do {
                            let file = try await recordingStore.save(recorded)
                            message = "Saved \(file.lastPathComponent). Space replays; l opens saved recordings."
                        } catch {
                            message = "Capture ready in memory, but saving failed: \(error.localizedDescription)"
                        }
                        return
                    }
                    if update.status == "failed" || update.status == "cancelled" {
                        armed = nil
                        message = update.message ?? "Recording \(update.status). Press a to arm again."
                        return
                    }
                    recordingStatus =
                        update.status == "recording" ? "● RECORDING EXTERNAL CHAT" : "ARMED · WAITING FOR CHAT"
                    if update.status == "recording" {
                        message =
                            "Collecting a bounded activation window. Replay is ready when the external chat finishes."
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
            } catch {
                let cancelled = Task.isCancelled
                var cleanupError: String?
                if let armed {
                    let client = recordingClient
                    do { try await Task.detached { try await client.cancel(armed) }.value } catch {
                        cleanupError = error.localizedDescription
                    }
                    do {
                        try await recordingStore.log(
                            id: armed.id, model: armed.selection.model, status: cancelled ? "cancelled" : "failed")
                    } catch { cleanupError = "Recording log failed: \(error.localizedDescription)" }
                }
                if armed == nil {
                    do {
                        try await recordingStore.log(
                            id: attemptID, model: "unavailable", status: cancelled ? "cancelled" : "arm_failed")
                    } catch { cleanupError = "Recording log failed: \(error.localizedDescription)" }
                }
                message = cancelled ? "Recording stopped. External chat continues." : error.localizedDescription
                if let cleanupError { message += " Cleanup failed: " + cleanupError }
            }
        }
    }

    private func applyCapture(_ recorded: StudioActivationCapture) {
        capture = recorded
        topologyData = recorded.topologyData
        playbackCursor = 0
        playbackSite =
            recorded.components?.isEmpty == false
            ? "components"
            : recorded.layers.contains { $0.site == "layer_input" } ? "layer_input" : "after_attention"
        offset = 0
    }

    private func openLibrary() {
        guard operation == nil else {
            message = "Stop the current recording with a or Esc before opening the library."
            return
        }
        playing = false
        operation = Task {
            defer { operation = nil }
            do {
                library = try await recordingStore.entries()
                librarySelection = 0
                message =
                    library?.isEmpty == true
                    ? "No saved recordings yet. Press a to record the next chat."
                    : "Choose a recording and press Enter to replay."
            } catch { message = "Cannot read the recording library: \(error.localizedDescription)" }
        }
    }

    private func loadLibrarySelection() {
        guard operation == nil, let library, library.indices.contains(librarySelection) else { return }
        let entry = library[librarySelection]
        operation = Task {
            defer { operation = nil }
            do {
                let recorded = try await recordingStore.load(entry)
                self.library = nil
                replayingSaved = true
                applyCapture(recorded)
                message = "Saved recording loaded. Space replays; ←→ step; v changes view; l returns to library."
            } catch { message = "Cannot open this recording: \(error.localizedDescription)" }
        }
    }

    private func togglePlayback() {
        guard let capture, !capture.playableTokenIndices.isEmpty else {
            message = "Press a to record the next external chat, or l to open a saved recording."
            return
        }
        if !playing, playbackCursor >= capture.playableTokenIndices.count - 1 { playbackCursor = 0 }
        playing.toggle()
        message = playing ? "Playing recorded measurements locally." : "Playback paused."
    }

    private func stepPlayback(_ delta: Int) {
        guard let capture else { return }
        playing = false
        playbackCursor = max(0, min(capture.playableTokenIndices.count - 1, playbackCursor + delta))
        message = "Playback paused. Space resumes; ←→ step through tokens."
    }

    private func advancePlayback() {
        guard playing, let capture else { return }
        if playbackCursor + 1 < capture.playableTokenIndices.count {
            playbackCursor += 1
        } else {
            playing = false
            message = "Playback complete. Space replays the recording."
        }
    }

    private func switchSite() {
        guard let capture else { return }
        let views = (capture.components?.isEmpty == false ? ["components"] : []) + capture.capturedSites
        guard let index = views.firstIndex(of: playbackSite), !views.isEmpty else { return }
        playbackSite = views[(index + 1) % views.count]
    }

    private func rebuildTopology(width: Int) {
        guard let topologyData, let object = try? JSONSerialization.jsonObject(with: topologyData) else { return }
        var illumination: [Int: Double]?
        var magnitudes: [Int: Double] = [:]
        var componentIllumination: [Int: [String: Double]]?
        var routedExperts: [Int: StudioActivationCapture.RoutingSample] = [:]
        if let capture, capture.playableTokenIndices.indices.contains(playbackCursor) {
            let tokenIndex = capture.playableTokenIndices[playbackCursor]
            let peak =
                capture.layers.filter { $0.site == playbackSite }.flatMap(\.samples).map { Double($0.rms) }.max() ?? 0
            if playbackSite == "components", let components = capture.components, !components.isEmpty {
                componentIllumination = [:]
                for component in components {
                    // One fixed recording-wide scale per component kind.
                    let peak = components.filter { $0.site == component.site }.flatMap(\.samples).map(\.rms).max() ?? 0
                    if let sample = component.samples.first(where: { $0.tokenIndex == tokenIndex }) {
                        componentIllumination?[component.index, default: [:]][component.site] =
                            peak > 0 ? log1p(sample.rms) / log1p(peak) : 0
                    }
                }
            }
            for route in playbackSite == "components" ? capture.expertRouting ?? [] : [] {
                if let sample = route.samples.first(where: { $0.tokenIndex == tokenIndex }) {
                    routedExperts[route.index] = sample
                }
            }
            illumination = [:]
            for layer in capture.layers where layer.site == playbackSite {
                if let sample = layer.samples.first(where: { $0.tokenIndex == tokenIndex }) {
                    magnitudes[layer.index] = Double(sample.rms)
                    illumination?[layer.index] = peak > 0 ? log1p(Double(sample.rms)) / log1p(peak) : 0
                }
            }
        }
        detail =
            StudioLayerMap.rows(
                object: object, width: width, roomier: TerminalSession.size().height >= 34, illumination: illumination,
                magnitudes: magnitudes, componentIllumination: componentIllumination, routedExperts: routedExperts)
            ?? []
        if let recordingStatus {
            detail.insert(.init(recordingStatus, tone: .heading), at: min(2, detail.count))
        }
        if let capture, capture.playableTokenIndices.indices.contains(playbackCursor) {
            let position = capture.playableTokenIndices[playbackCursor]
            let token = capture.tokens.first { $0.position == position }
            let status = playing ? "▶ PLAYING" : "Ⅱ PAUSED"
            let site =
                componentIllumination != nil
                ? "component activity"
                : playbackSite == "layer_input" ? "layer input" : "after attention"
            detail.insert(
                .init(
                    "\(status)  \(playbackCursor + 1)/\(capture.playableTokenIndices.count) · \(site) · token \(position)",
                    tone: .heading), at: 2)
            detail.insert(.init("Token: \(token?.text ?? "")", tone: .spine), at: 3)
            detail.append(.init(capture.selectionNote, tone: .muted))
            detail.append(
                .init(
                    componentIllumination != nil
                        ? "Brightness = each component's output RMS; expert tiles identify actual selected routes."
                        : "Brightness = whole-layer residual RMS; this recording has no component measurements.",
                    tone: .muted))
            if componentIllumination != nil {
                detail.append(
                    .init(
                        "Unmeasured capacity stays dim. Expert tiles show routes, not causal importance.",
                        tone: .muted))
            }
            if let cached = capture.cachedPromptTokenCount, cached > 0 {
                detail.append(.init("\(cached) cached prompt tokens were not re-evaluated.", tone: .muted))
            }
            detail.append(.init("Recorded output: \(capture.answer)", tone: .text))
        }
    }

    private func draw() throws {
        rebuildTopology(width: max(1, TerminalSession.size().width - 2))
        try terminal?.draw { frame in
            let rows: [StudioInspectionRow]
            if showingModelInformation {
                rows = Array(
                    (modelInformation?.rows(width: max(1, frame.area.width - 2))
                        ?? [.init("MODEL INFORMATION", tone: .heading), .init(informationStatus, tone: .muted)])
                        .dropFirst(offset))
            } else if let library {
                let visible = max(1, frame.area.height - 10)
                let start = max(0, librarySelection - visible + 1)
                rows =
                    [.init("SAVED RECORDINGS", tone: .heading), ""]
                    + library.dropFirst(start).prefix(visible).enumerated().map { index, entry in
                        let date = Date(timeIntervalSince1970: entry.createdAt).formatted(
                            date: .abbreviated, time: .shortened)
                        return StudioInspectionRow(
                            "\(start + index == librarySelection ? "›" : " ") \(date) · \(entry.model) · \(entry.id.prefix(8))"
                        )
                    }
            } else if detail.isEmpty {
                let visible = max(1, frame.area.height - 8)
                let start = max(0, selected - visible + 1)
                rows = models.dropFirst(start).prefix(visible).enumerated().map { index, model in
                    StudioInspectionRow(
                        "\(start + index == selected ? "›" : " ") \(model.name)  ·  \(model.architecture)  ·  \(model.supported ? model.quantization ?? "BF16/FP16" : "unavailable")"
                    )
                }
            } else {
                rows = Array(detail.dropFirst(offset))
            }
            Self.render(
                frame: &frame, state: state, rows: rows, message: showingModelInformation ? informationStatus : message,
                footer: showingModelInformation
                    ? "↑↓ scroll · r refresh · i layers · Esc back · q quit"
                    : library != nil
                        ? "↑↓ select · Enter open · a record · Esc back · q quit"
                        : (topologyData != nil
                            ? "m model info · a record/stop · Space replay · ←→ token · v view · l library · ↑↓ scroll · Esc back · q quit"
                            : nil))
        }
    }

    /// Builds a frame in terminal cells; control characters in model metadata never reach the terminal.
    static func render(
        frame: inout Frame, state: ModelControlState?, rows: [StudioInspectionRow], message: String,
        footer: String? = nil
    ) {
        let width = max(1, frame.area.width - 2)
        func row(_ text: String, y: Int, bold: Bool = false) {
            guard y >= 0, y < frame.area.height else { return }
            let safe = String(
                text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            frame.render(
                Paragraph(TextLayout(safe, width: width), style: Style(bold: bold)),
                in: Rect(x: 1, y: y, width: width, height: 1))
        }
        row("midnight studio", y: 0, bold: true)
        row(state?.endpoint ?? "Connecting…", y: 1)
        row(
            "\(state?.mode ?? "external") · \(state?.phase ?? "idle") · \(state?.activeProfile?.servedModelName ?? "No owned model")",
            y: 2, bold: true)
        row(state?.message ?? "", y: 3)
        for (index, value) in rows.prefix(max(0, frame.area.height - 8)).enumerated() {
            let spans = value.segments.map { segment in
                let safe = segment.text.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) ? " " : String($0)
                }.joined()
                return TextSpan(safe, style: inspectionStyle(segment))
            }
            frame.render(
                Paragraph(TextLayout(spans, width: width)),
                in: Rect(x: 1, y: index + 5, width: width, height: 1))
        }
        row(message, y: frame.area.height - 2)
        row(
            footer
                ?? "↑↓ select · Enter load · i layers · m model info · a record · l library · s status · u unload · p save · r refresh · q quit",
            y: frame.area.height - 1)
    }

    private static func inspectionStyle(_ segment: StudioInspectionRow.Segment) -> Style {
        var style: Style =
            switch segment.tone {
            case .text: Style(foreground: .rgb(208, 216, 226))
            case .muted: Style(foreground: .rgb(127, 145, 159))
            case .heading: Style(foreground: .rgb(231, 243, 240), bold: true)
            case .spine: Style(foreground: .rgb(113, 193, 176))
            case .attention: Style(foreground: .rgb(114, 200, 255))
            case .convolution: Style(foreground: .rgb(236, 190, 126))
            case .experts: Style(foreground: .rgb(180, 154, 247))
            case .feedForward: Style(foreground: .rgb(91, 218, 178))
            }
        if let intensity = segment.intensity, intensity.isFinite {
            let level = min(1, max(0, intensity))
            if case .rgb(let r, let g, let b) = style.foreground {
                func channel(_ base: UInt8) -> UInt8 {
                    UInt8(min(255, Double(base) * (0.30 + 0.70 * level)))
                }
                style.foreground = .rgb(channel(r), channel(g), channel(b))
            }
            style.background = .terminalDefault
            style.bold = false
        }
        return style
    }
}
