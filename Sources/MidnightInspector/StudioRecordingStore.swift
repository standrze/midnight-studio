import Foundation

/// Local artifacts contain model metadata and measured tokens, never connection credentials.
actor StudioRecordingStore {
    struct Entry: Identifiable, Sendable {
        let id: String
        let model: String
        let createdAt: Double
        let url: URL
    }

    private let directory: URL
    private let logURL: URL

    init(stateDirectory: URL) {
        directory = stateDirectory.appendingPathComponent("recordings", isDirectory: true)
        logURL = stateDirectory.appendingPathComponent("recordings.jsonl")
    }

    func save(_ capture: StudioActivationCapture) throws -> URL {
        guard let id = capture.recordingID, UUID(uuidString: id) != nil, let createdAt = capture.createdAt else {
            throw ConfigurationError("The capture has no recording identity and cannot be saved.")
        }
        try prepareDirectory()
        let artifact = directory.appendingPathComponent(id + ".json")
        var object: [String: Any] = [
            "format": "midnight-studio-recording-v1", "id": id, "createdAt": createdAt,
            "model": try JSONSerialization.jsonObject(with: capture.topologyData),
            "trace": try JSONSerialization.jsonObject(with: capture.captureData),
            "selectedLayers": capture.capturedLayerIndices, "selectedSites": capture.capturedSites,
        ]
        if let cached = capture.cachedPromptTokenCount { object["cachedPromptTokenCount"] = cached }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 16 * 1024 * 1024 else { throw ConfigurationError("The saved recording exceeds 16 MiB.") }
        try data.write(to: artifact, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
        try log(id: id, model: capture.model, status: "completed", artifact: artifact.lastPathComponent)
        return artifact
    }

    func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var entries: [Entry] = []
        for file in files where file.pathExtension == "json" {
            let object = try read(file)
            guard let id = object["id"] as? String, UUID(uuidString: id) != nil,
                file.lastPathComponent == id + ".json", let createdAt = object["createdAt"] as? Double,
                createdAt.isFinite, let model = object["model"] as? [String: Any], let modelID = model["id"] as? String
            else { throw ConfigurationError("Invalid saved recording: \(file.lastPathComponent)") }
            entries.append(Entry(id: id, model: modelID, createdAt: createdAt, url: file))
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func load(_ entry: Entry) throws -> StudioActivationCapture {
        guard
            entry.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                == directory.standardizedFileURL.resolvingSymlinksInPath().path
        else {
            throw ConfigurationError("Choose a capture from the recording library.")
        }
        let object = try read(entry.url)
        guard let model = object["model"], let trace = object["trace"],
            let layers = object["selectedLayers"] as? [Int], let sites = object["selectedSites"] as? [String],
            object["id"] as? String == entry.id
        else { throw ConfigurationError("The saved recording is incomplete.") }
        return try StudioRecordingClient.decodeCapture(
            topology: JSONSerialization.data(withJSONObject: model),
            trace: JSONSerialization.data(withJSONObject: trace),
            id: entry.id, createdAt: entry.createdAt, cachedPromptTokenCount: object["cachedPromptTokenCount"] as? Int,
            expectedModel: entry.model, layers: layers, sites: sites)
    }

    func log(id: String, model: String, status: String, artifact: String? = nil) throws {
        try prepareDirectory()
        var object: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970, "model": model, "id": id, "status": status,
        ]
        if let artifact { object["artifact"] = "recordings/" + artifact }
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard
                FileManager.default.createFile(
                    atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw ConfigurationError("Cannot create the recording log.") }
        }
        let file = try FileHandle(forWritingTo: logURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: line)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func read(_ file: URL) throws -> [String: Any] {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= 16 * 1024 * 1024
        else { throw ConfigurationError("The saved capture is not a regular JSON file under 16 MiB.") }
        let data = try Data(contentsOf: file)
        guard data.count <= 16 * 1024 * 1024,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["format"] as? String == "midnight-studio-recording-v1"
        else { throw ConfigurationError("Unsupported saved recording format.") }
        return object
    }
}
