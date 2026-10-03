import Darwin
import Foundation

@main
struct MidnightInspector {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Midnight Studio: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let invocation = try StudioInvocation(arguments: Array(CommandLine.arguments.dropFirst()))
        let configuration = try InspectorConfiguration(arguments: invocation.configurationArguments)
        if configuration.showHelp {
            print(StudioInvocation.usage)
            return
        }
        try await StudioCommandLine.run(invocation, configuration: configuration)
    }
}
