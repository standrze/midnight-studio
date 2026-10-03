import Foundation
import Testing

@testable import MidnightInspector

struct StudioLayoutTests {
    @Test func siblingExecutablesAndPersistentDataDoNotDependOnWorkingDirectory() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = root.appendingPathComponent("midnight-studio")
        let home = root.appendingPathComponent("home")
        try write(root.appendingPathComponent("midnight/Package.swift"))
        let runtime = root.appendingPathComponent("midnight/.build/release/midnight")
        for executable in [runtime] { try write(executable, executable: true) }

        let configuration = try InspectorConfiguration(projectDirectory: studio, homeDirectory: home)
        #expect(configuration.midnightBinary == runtime)
        #expect(configuration.stateDirectory.path == home.appendingPathComponent(".midnight/studio").path)
        #expect(
            configuration.modelRoots.map(\.path) == [
                home.appendingPathComponent(".midnight/models").path,
                root.appendingPathComponent("midnight/tmp/models").path,
            ])
    }

    @Test func installedExecutablesWorkWithoutSiblingBuilds() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let names = ["midnight-runner"]
        let executables = names.map { home.appendingPathComponent(".midnight/bin/\($0)") }
        for executable in executables { try write(executable, executable: true) }
        let configuration = try InspectorConfiguration(
            projectDirectory: root.appendingPathComponent("midnight-studio"), homeDirectory: home)
        #expect(configuration.midnightBinary == executables[0])
    }

    @Test func projectDiscoveryFollowsTheBuiltExecutableFromAnUnrelatedDirectory() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = root.appendingPathComponent("midnight-studio")
        try write(studio.appendingPathComponent("Package.swift"))
        try write(studio.appendingPathComponent("Sources/MidnightInspector/InspectorConfiguration.swift"))
        let discovered = InspectorConfiguration.projectRoot(
            currentDirectory: root.appendingPathComponent("elsewhere"),
            executable: studio.appendingPathComponent(".build/arm64-apple-macosx/release/midnight-studio"),
            sourceFile: root.appendingPathComponent(
                "old-checkout/Sources/MidnightInspector/InspectorConfiguration.swift"))
        #expect(discovered.path == studio.path)
    }

    @Test func nestedSourceCheckoutKeepsRuntimeDiscoveryDuringMigration() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("midnight")
        try write(runtime.appendingPathComponent("Package.swift"))
        try write(runtime.appendingPathComponent("Sources/ModelRunnerCore/LocalModelRunner.swift"))
        let binary = runtime.appendingPathComponent(".build/debug/midnight")
        try write(binary, executable: true)
        let configuration = try InspectorConfiguration(
            projectDirectory: runtime.appendingPathComponent("apps/studio"),
            homeDirectory: root.appendingPathComponent("home"))
        #expect(configuration.midnightBinary == binary)
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
}
