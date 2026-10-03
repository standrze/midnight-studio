import Foundation

struct InspectorConnection: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let url: URL
}

struct InspectorConfiguration: Sendable {
    var port = 8090
    var managedPort = 8082
    var midnightBinary: URL
    var quantizerBinary: URL
    var trainerBinary: URL
    var studioLibrary: URL
    var modelRoots: [URL]
    var stateDirectory: URL
    var connections = [
        InspectorConnection(id: "primary", name: "Primary", url: URL(string: "http://127.0.0.1:8080")!)
    ]
    var showHelp = false

    static let usage = """
    Midnight Studio — view loaded layers, prompt activations, and model controls.

    Usage: midnight-studio [options] (midnight-inspector is also supported)
      --midnight-url URL   Primary Midnight server (default http://127.0.0.1:8080)
      --compare-url URL    Optional second Midnight server for model comparison
      --port PORT          Local web app port (default 8090)
      --midnight-binary PATH  Midnight executable (sibling build or ~/.midnight/bin/midnight-runner)
      --quantizer-binary PATH  Native model-runner-quantize worker
      --trainer-binary PATH    Native midnight-studio-worker (training and shard conversion)
      --studio-library PATH   Downloaded and quantized models (default ~/.midnight/models/studio)
      --model-root PATH    Local model catalog root; repeat for multiple roots
                          (defaults ~/.midnight/models and sibling Midnight tmp/models)
      --state-directory PATH  Saved profiles and jobs (default ~/.midnight/studio)
      --managed-port PORT  Port for the Midnight process started by controls (default 8082)
      --help              Show this help

    Open http://127.0.0.1:8090 for layers or /control for model controls.
    The app and its managed Midnight process bind only to loopback.
    """

    init(arguments: [String] = [], projectDirectory: URL? = nil,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let project = (projectDirectory ?? Self.projectRoot()).standardizedFileURL
        let runtime = Self.runtimeRoot(for: project)
        let quantization = runtime.deletingLastPathComponent().appendingPathComponent("midnight-quantization")
        func executable(_ name: String, package: URL, installedName: String? = nil) -> URL {
            let candidates = [
                package.appendingPathComponent(".build/release/\(name)"),
                package.appendingPathComponent(".build/debug/\(name)"),
                homeDirectory.appendingPathComponent(".midnight/bin/\(installedName ?? name)"),
            ]
            return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? candidates[0]
        }
        quantizerBinary = executable("model-runner-quantize", package: quantization)
        trainerBinary = executable("midnight-studio-worker", package: project.appendingPathComponent("Workers"))
        studioLibrary = homeDirectory.appendingPathComponent(".midnight/models/studio")
        midnightBinary = executable("midnight", package: runtime, installedName: "midnight-runner")
        modelRoots = [
            homeDirectory.appendingPathComponent(".midnight/models", isDirectory: true),
            runtime.appendingPathComponent("tmp/models", isDirectory: true),
        ]
        stateDirectory = homeDirectory.appendingPathComponent(".midnight/studio", isDirectory: true)
        var hasExplicitModelRoots = false
        var arguments = arguments.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--help", "-h":
                showHelp = true
            case "--port", "--managed-port":
                guard let raw = arguments.next(), let port = Int(raw), (1...65_535).contains(port) else {
                    throw ConfigurationError("\(argument) must be an integer from 1 to 65535.")
                }
                if argument == "--port" { self.port = port } else { managedPort = port }
            case "--midnight-binary", "--model-root", "--state-directory", "--quantizer-binary", "--trainer-binary", "--studio-library":
                guard let raw = arguments.next(), !raw.isEmpty, !raw.contains("\0") else {
                    throw ConfigurationError("\(argument) requires a filesystem path.")
                }
                let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
                switch argument {
                case "--midnight-binary": midnightBinary = path
                case "--quantizer-binary": quantizerBinary = path
                case "--trainer-binary": trainerBinary = path
                case "--studio-library": studioLibrary = path
                case "--state-directory": stateDirectory = path
                default:
                    if !hasExplicitModelRoots { modelRoots = []; hasExplicitModelRoots = true }
                    if !modelRoots.contains(path) { modelRoots.append(path) }
                }
            case "--midnight-url", "--compare-url":
                guard let raw = arguments.next() else {
                    throw ConfigurationError("\(argument) requires a URL.")
                }
                let url = try Self.validateUpstream(raw)
                let id = argument == "--midnight-url" ? "primary" : "comparison"
                let name = id == "primary" ? "Primary" : "Comparison"
                connections.removeAll { $0.id == id }
                connections.append(InspectorConnection(id: id, name: name, url: url))
            default:
                throw ConfigurationError("Unknown option: \(argument). Use --help for usage.")
            }
        }
        connections.sort { $0.id == "primary" && $1.id != "primary" }
        guard port != managedPort else {
            throw ConfigurationError("--managed-port must differ from the Studio --port.")
        }
        guard !connections.contains(where: {
            ["127.0.0.1", "localhost", "::1"].contains($0.url.host ?? "") && ($0.url.port ?? 80) == managedPort
        }) else {
            throw ConfigurationError("--managed-port must differ from the configured external Midnight ports.")
        }
    }

    var controlConfiguration: ModelControlConfiguration {
        ModelControlConfiguration(
            executableURL: midnightBinary,
            modelRoots: modelRoots + [studioLibrary],
            stateDirectory: stateDirectory,
            managedPort: managedPort,
            externalURL: connections.first(where: { $0.id == "primary" })!.url
        )
    }

    static func projectRoot(
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        sourceFile: URL = URL(fileURLWithPath: #filePath)
    ) -> URL {
        // Resolve from the executable before the working directory, so running a
        // built Studio from another checkout still uses its own workers.
        for start in [executable.deletingLastPathComponent(), currentDirectory, sourceFile.deletingLastPathComponent()] {
            if let root = ancestor(start, containing: "Sources/MidnightInspector/InspectorConfiguration.swift") {
                return root
            }
        }
        return sourceFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func runtimeRoot(for project: URL) -> URL {
        let sibling = project.deletingLastPathComponent().appendingPathComponent("midnight", isDirectory: true)
        if FileManager.default.fileExists(atPath: sibling.appendingPathComponent("Package.swift").path) {
            return sibling
        }
        // Supports a source checkout nested inside the runtime during migration.
        return ancestor(project.deletingLastPathComponent(), containing: "Sources/ModelRunnerCore/LocalModelRunner.swift") ?? sibling
    }

    private static func ancestor(_ start: URL, containing marker: String) -> URL? {
        var directory = start.standardizedFileURL
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func validateUpstream(_ raw: String) throws -> URL {
        guard let parts = URLComponents(string: raw),
            ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/",
            parts.port == nil || (1...65_535).contains(parts.port!)
        else {
            throw ConfigurationError("Midnight URLs must be http(s) server origins, such as http://127.0.0.1:8080, without credentials, paths, or queries.")
        }
        guard let url = parts.url else {
            throw ConfigurationError("Invalid Midnight server URL.")
        }
        return url
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
