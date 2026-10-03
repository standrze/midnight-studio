import Darwin
import Foundation

enum ModelControlChildStatus: Sendable, Equatable {
    case running
    case exited(Int32)
}

protocol ModelControlChild: Sendable {
    var processIdentifier: Int32 { get }
    func status() -> ModelControlChildStatus
    func terminate()
    func forceTerminate()
    func drainLogs() -> [String]
}

struct ModelControlLaunch: Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL
    let instanceID: String
}

/// One Process object is the ownership boundary. Never searches for or signals an
/// existing server. A bounded pipe buffer also prevents verbose startup logs from
/// growing the Inspector's memory indefinitely.
final class ModelControlProcess: ModelControlChild, @unchecked Sendable {
    private let process: Process
    private let output: Pipe
    private let lock = NSLock()
    private var buffered = Data()

    init(_ launch: ModelControlLaunch) throws {
        process = Process()
        output = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "MODEL_STACK_CONFIG")
        environment["MIDNIGHT_CONTROL_INSTANCE"] = launch.instanceID
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.append(data)
        }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    deinit { output.fileHandleForReading.readabilityHandler = nil }
    var processIdentifier: Int32 { process.processIdentifier }
    func status() -> ModelControlChildStatus {
        process.isRunning ? .running : .exited(process.terminationStatus)
    }
    func terminate() { if process.isRunning { process.terminate() } }
    func forceTerminate() { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
    func drainLogs() -> [String] {
        lock.withLock {
            let value = String(decoding: buffered, as: UTF8.self)
            buffered.removeAll(keepingCapacity: true)
            return value.split(whereSeparator: \.isNewline).map { String($0.prefix(2048)) }
        }
    }
    private func append(_ data: Data) {
        lock.withLock {
            buffered.append(data)
            if buffered.count > 64 * 1024 { buffered.removeFirst(buffered.count - 64 * 1024) }
        }
    }

    static func requireAvailablePort(_ port: Int) throws {
        guard (1...65535).contains(port) else { throw ModelControlError("The managed server port is invalid.") }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ModelControlError("Could not check the managed server port.", code: "port_unavailable", status: 503) }
        defer { Darwin.close(descriptor) }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw ModelControlError("Port \(port) is already in use. Studio will not replace or attach to that process. Choose another --managed-port when starting Studio.", code: "port_unavailable", status: 409)
        }
    }
}
