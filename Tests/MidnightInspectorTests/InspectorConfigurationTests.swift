import Foundation
import Testing

@testable import MidnightInspector

struct InspectorConfigurationTests {
    @Test func configurationKeepsExplicitOriginsAndValidatesOptions() throws {
        let configuration = try InspectorConfiguration(arguments: [
            "--compare-url", "http://127.0.0.1:8081",
            "--midnight-url", "http://localhost:8080",
        ])
        #expect(configuration.connections.map(\.id) == ["primary", "comparison"])
        #expect(configuration.connections[0].url.absoluteString == "http://localhost:8080")
        for arguments in [
            ["--port", "0"], ["--port", "65536"], ["--compare-url"],
            ["--midnight-url", "file:///tmp/model"],
            ["--midnight-url", "http://user:password@localhost:8080"],
            ["--midnight-url", "http://localhost:8080/v1"],
            ["--midnight-url", "http://localhost:8080?url=other"],
        ] {
            #expect(throws: ConfigurationError.self) { try InspectorConfiguration(arguments: arguments) }
        }
    }

    @Test func launchConfigurationAcceptsOnlyFixedCLIPathsAndDistinctPorts() throws {
        let configuration = try InspectorConfiguration(arguments: [
            "--midnight-binary", "/tmp/custom-midnight", "--model-root", "/tmp/models-one",
            "--model-root", "/tmp/models-two", "--state-directory", "/tmp/inspector-profiles",
            "--managed-port", "8182",
        ])
        #expect(configuration.midnightBinary.path == "/tmp/custom-midnight")
        #expect(configuration.modelRoots.map(\.path) == ["/tmp/models-one", "/tmp/models-two"])
        #expect(configuration.stateDirectory.path == "/tmp/inspector-profiles")
        #expect(configuration.managedPort == 8182)
        for arguments in [
            ["--managed-port", "0"], ["--managed-port", "65536"],
            ["--managed-port", "8080"],
            ["--compare-url", "http://127.0.0.1:8082"],
            ["--model-root"], ["--midnight-binary"], ["--state-directory", ""],
        ] {
            #expect(throws: ConfigurationError.self) { try InspectorConfiguration(arguments: arguments) }
        }
    }
}
