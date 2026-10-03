import Foundation
import Testing

@testable import MidnightInspector

actor FakeControlRuntime: ModelControlRuntime {
    typealias Readiness = @Sendable (URL, String, String, Int32) async throws -> Bool
    private let readiness: Readiness
    private var request: ManagedModelRequest?
    private var operationID: String?
    private var generation: UInt64 = 0
    private var failure: String?
    private var rejection: ModelControlError?
    private var loads: [ManagedModelRequest] = []
    init(readiness: @escaping Readiness = { _, _, _, _ in true }) { self.readiness = readiness }
    func failNextLoad(_ message: String?) { failure = message }
    func rejectNextLoad(_ error: ModelControlError) { rejection = error }
    func loadedRequests() -> [ManagedModelRequest] { loads }
    func state(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        let ready = if let request { try await readiness(endpoint, request.name, instanceID, processID) } else { false }
        return ManagedRuntimeState(
            instanceID: instanceID, processID: processID,
            phase: request == nil ? "empty" : ready ? "ready" : "loading", operationID: operationID,
            modelGeneration: generation, loadedModel: ready ? .init(id: request!.name) : nil,
            targetModel: request?.name, lastError: failure)
    }
    func load(_ model: ManagedModelRequest, at endpoint: URL, instanceID: String, processID: Int32) async throws
        -> ManagedRuntimeState
    {
        if let rejection {
            self.rejection = nil
            throw rejection
        }
        loads.append(model)
        request = failure == nil ? model : nil
        operationID = UUID().uuidString
        generation += 1
        return try await state(at: endpoint, instanceID: instanceID, processID: processID)
    }
    func unload(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        request = nil
        failure = nil
        operationID = UUID().uuidString
        generation += 1
        return try await state(at: endpoint, instanceID: instanceID, processID: processID)
    }
}

struct ModelControlRuntimeTests {
    @Test func foreignRuntimeNeverReceivesMutation() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8082")!
        let client = ModelControlRuntimeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/runtime")
            return UpstreamResponse(
                status: 200,
                body: Data(#"{"instanceID":"foreign","processID":4242,"phase":"empty","modelGeneration":0}"#.utf8))
        }
        do {
            _ = try await client.unload(at: endpoint, instanceID: "owned", processID: 4242)
            Issue.record("Foreign identity must fail")
        } catch let error as ModelControlError { #expect(error.code == "runtime_identity_mismatch") }
    }

    @Test func loadVerifiesIdentityAndUsesJSONWithAnOperationReceipt() async throws {
        let recorder = RequestRecorder()
        let client = ModelControlRuntimeClient { request in
            await recorder.append(request)
            let state = ManagedRuntimeState(
                instanceID: "owned", processID: 4242,
                phase: request.httpMethod == "POST" ? "loading" : "empty",
                operationID: request.httpMethod == "POST" ? "operation-1" : nil,
                modelGeneration: 0, loadedModel: nil, targetModel: "--port=9000", lastError: nil)
            return UpstreamResponse(
                status: request.httpMethod == "POST" ? 202 : 200, body: try JSONEncoder().encode(state))
        }
        let model = ManagedModelRequest(
            model: "/tmp/a model", name: "--port=9000", adapter: "/tmp/adapter",
            maxTokens: 128, contextLength: 4096, prefillStepSize: 256, kvCompression: "none", engine: "auto")
        let state = try await client.load(
            model, at: URL(string: "http://127.0.0.1:8082")!, instanceID: "owned", processID: 4242)
        #expect(state.operationID == "operation-1")
        let requests = await recorder.values
        #expect(requests.map { $0.httpMethod } == ["GET", "POST"])
        let request = try #require(requests.last)
        #expect(request.url?.path == "/v1/runtime/load")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let decoded = try JSONDecoder().decode(ManagedModelRequest.self, from: #require(request.httpBody))
        #expect(decoded.name == "--port=9000")
        #expect(decoded.adapter == "/tmp/adapter")
        #expect(decoded.contextLength == 4096)
    }
}

private actor RequestRecorder {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}

actor SupersededControlRuntime: ModelControlRuntime {
    private var modelName: String?
    func state(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        ManagedRuntimeState(
            instanceID: instanceID, processID: processID, phase: modelName == nil ? "empty" : "ready",
            operationID: modelName == nil ? nil : "different-operation", modelGeneration: 1,
            loadedModel: modelName.map { .init(id: $0) }, targetModel: nil, lastError: nil)
    }
    func load(_ model: ManagedModelRequest, at endpoint: URL, instanceID: String, processID: Int32) async throws
        -> ManagedRuntimeState
    {
        modelName = model.name
        return ManagedRuntimeState(
            instanceID: instanceID, processID: processID, phase: "loading", operationID: "accepted-operation",
            modelGeneration: 0, loadedModel: nil, targetModel: model.name, lastError: nil)
    }
    func unload(at endpoint: URL, instanceID: String, processID: Int32) async throws -> ManagedRuntimeState {
        throw ModelControlError("Unexpected unload in operation identity test")
    }
}
