import Darwin
import Foundation
import Hummingbird

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
        if invocation.command != .web {
            try await StudioCommandLine.run(invocation, configuration: configuration)
            return
        }
        let modelControl = ModelControlManager(configuration: configuration.controlConfiguration)
        let studioJobs = StudioJobs(configuration: configuration)
        let server = InspectorServer(configuration: configuration, modelControl: modelControl, studioJobs: studioJobs)
        let app = Application(
            router: server.router(),
            configuration: .init(address: .hostname("127.0.0.1", port: configuration.port))
        )
        print("Midnight Studio: http://127.0.0.1:\(configuration.port)")
        print("  Model controls: http://127.0.0.1:\(configuration.port)/control")
        print("  Model preparation: http://127.0.0.1:\(configuration.port)/prepare")
        print("  Managed Midnight: http://127.0.0.1:\(configuration.managedPort)")
        for connection in configuration.connections {
            print("  \(connection.name): \(connection.url.absoluteString)")
        }
        do {
            try await app.runService()
        } catch {
            await studioJobs.shutdown()
            await modelControl.shutdown()
            throw error
        }
        await studioJobs.shutdown()
        await modelControl.shutdown()
    }
}
