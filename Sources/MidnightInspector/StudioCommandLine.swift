import Darwin
import Foundation

/// Parses terminal commands separately from the existing connection and catalog options.
struct StudioInvocation {
    enum Command: String { case console, models, status, inspect, trace }
    var command: Command = .console
    var configurationArguments: [String] = []
    var requestFile: String?
    var comparison = false

    static let usage = """
        Midnight Studio — terminal model workbench (loom + weft)

        midnight-studio                         Interactive terminal workbench
        midnight-studio models                  Local checkpoint catalog as JSON
        midnight-studio status                  Midnight runtime state as JSON
        midnight-studio inspect                 Model topology as JSON
        midnight-studio trace --request FILE     Capture activations using a JSON request

        --midnight-url URL   Midnight origin (default http://127.0.0.1:8080)
        --compare-url URL    Second Midnight origin
        --comparison        Read from the second origin
        --model-root PATH   Catalog root; repeat for multiple roots
        --midnight-binary PATH  Executable for models owned by the interactive session
        --state-directory PATH Saved Studio profiles (default ~/.midnight/studio)
        --managed-port PORT Owned Midnight port (default 8082)
        --help              Show usage

        Interactive keys: arrows select/scroll, Enter load, u unload, e external,
        i inspect, a record next chat, Space replay, l saved recordings,
        s status, p save profile, r refresh, Esc cancel/back, q quit.
        Training, calibration and quantization commands belong to ../afterglow.
        Quitting releases only the Midnight process started by this session.
        """

    init(arguments: [String]) throws {
        var remaining = arguments
        if let first = remaining.first, !first.hasPrefix("-") {
            guard let command = Command(rawValue: first) else { throw ConfigurationError("Unknown command: \(first)") }
            self.command = command
            remaining.removeFirst()
        }
        var iterator = remaining.makeIterator()
        while let argument = iterator.next() {
            if argument == "--request" {
                guard let path = iterator.next(), !path.isEmpty else {
                    throw ConfigurationError("--request requires a JSON file.")
                }
                requestFile = path
            } else if argument == "--comparison" {
                comparison = true
            } else {
                configurationArguments.append(argument)
                if argument != "--help" && argument != "-h" {
                    guard let value = iterator.next() else { throw ConfigurationError("\(argument) requires a value.") }
                    configurationArguments.append(value)
                }
            }
        }
        if command == .trace, requestFile == nil, !configurationArguments.contains("--help"),
            !configurationArguments.contains("-h")
        {
            throw ConfigurationError("trace requires --request FILE.")
        }
        if command != .trace, requestFile != nil { throw ConfigurationError("--request is only valid for trace.") }
    }
}

/// Keeps script output free of terminal escape sequences and interactive process ownership.
enum StudioCommandLine {
    static func run(_ invocation: StudioInvocation, configuration: InspectorConfiguration) async throws {
        if invocation.command == .console {
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
                ProcessInfo.processInfo.environment["TERM"] != "dumb"
            else {
                throw ConfigurationError(
                    "Interactive Studio requires a terminal. Use models, status, inspect or trace for scripts.")
            }
            let manager = ModelControlManager(configuration: configuration.controlConfiguration)
            do {
                try await StudioTerminal(manager: manager, stateDirectory: configuration.stateDirectory).run()
            } catch {
                await manager.shutdown()
                throw error
            }
            await manager.shutdown()
            return
        }
        if invocation.command == .models {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let models = ModelControlCatalog(roots: configuration.controlConfiguration.modelRoots).models()
            print(String(decoding: try encoder.encode(models), as: UTF8.self))
            return
        }
        let id = invocation.comparison ? "comparison" : "primary"
        guard let origin = configuration.connections.first(where: { $0.id == id })?.url else {
            throw ConfigurationError("Configure --compare-url to use --comparison.")
        }
        let path: String
        switch invocation.command {
        case .status: path = "v1/runtime"
        case .inspect: path = "v1/inspector/model"
        case .trace: path = "v1/inspector/trace"
        default: throw ConfigurationError("This command is not a script operation.")
        }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        if let file = invocation.requestFile {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 else {
                throw ConfigurationError("Trace requests may not exceed 32 KiB.")
            }
            let body = try Data(contentsOf: url)
            guard try JSONSerialization.jsonObject(with: body) is [String: Any] else {
                throw ConfigurationError("Trace requests must be JSON objects.")
            }
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let response = try await InspectorHTTPClient().send(request)
        guard (200..<300).contains(response.status) else {
            throw ConfigurationError(
                "Midnight returned HTTP \(response.status): \(String(decoding: response.body, as: UTF8.self))")
        }
        FileHandle.standardOutput.write(response.body)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
