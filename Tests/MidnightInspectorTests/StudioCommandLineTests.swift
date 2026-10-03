import Testing

@testable import MidnightInspector

struct StudioCommandLineTests {
    @Test func defaultIsTerminal() throws {
        #expect(try StudioInvocation(arguments: []).command == .console)
        #expect(try StudioInvocation(arguments: ["web"]).command == .web)
    }
    @Test func separatesCommandFromConnectionOptions() throws {
        let command = try StudioInvocation(arguments: [
            "trace", "--request", "trace.json", "--midnight-url", "http://localhost:8080", "--comparison",
        ])
        #expect(command.requestFile == "trace.json")
        #expect(command.comparison)
        #expect(command.configurationArguments == ["--midnight-url", "http://localhost:8080"])
    }
    @Test func invalidInvocationFailsBeforeTerminalModes() {
        for arguments in [["unknown"], ["trace"], ["models", "--request", "x"], ["--model-root"]] {
            #expect(throws: ConfigurationError.self) { try StudioInvocation(arguments: arguments) }
        }
    }
}
