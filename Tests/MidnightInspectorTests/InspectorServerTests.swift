import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import MidnightInspector

struct InspectorServerTests {
    @Test func configurationKeepsExplicitOriginsAndValidatesOptions() throws {
        let configuration = try InspectorConfiguration(arguments: [
            "--compare-url", "http://127.0.0.1:8081",
            "--midnight-url", "http://localhost:8080", "--port", "8092",
        ])
        #expect(configuration.port == 8092)
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

    @Test func listsConnectionsAndForwardsSelectedModel() async throws {
        let configuration = try InspectorConfiguration(arguments: ["--compare-url", "http://127.0.0.1:8081"])
        let payload = Data(#"{"name":"comparison model","layers":[]}"#.utf8)
        let server = InspectorServer(configuration: configuration) { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:8081/v1/inspector/model")
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            return UpstreamResponse(status: 200, body: payload)
        }
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(uri: "/api/connections", method: .get) { response in
                #expect(response.status == .ok)
                let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: [[String: String]]])
                #expect(object["connections"]?.map { $0["id"] } == ["primary", "comparison"])
            }
            try await client.execute(uri: "/api/model?connection=comparison", method: .get) { response in
                #expect(response.status == .ok)
                #expect(Data(response.body.readableBytesView) == payload)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await client.execute(uri: "/api/model?connection=http://other-server", method: .get) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func forwardsQuestionAndPreservesUpstreamRejection() async throws {
        let question = #"{"question":"Why is the sky blue?","maxTokens":16,"layers":[2],"sites":["layer_input"],"tokenPositions":{"prefill":[-1],"decode":[0]},"capture":"summary","maxCaptureBytes":1048576,"model":"fixture","runtimeGeneration":7}"#
        let upstreamError = Data(#"{"error":{"message":"Model is busy","code":"model_busy"}}"#.utf8)
        let server = InspectorServer(configuration: try .init()) { request in
            #expect(request.url?.path == "/v1/inspector/trace")
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data(question.utf8))
            return UpstreamResponse(status: 409, body: upstreamError)
        }
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(
                uri: "/api/trace", method: .post,
                headers: [.contentType: "application/json", .origin: "http://127.0.0.1:8090"],
                body: .init(string: question)
            ) { response in
                #expect(response.status == .conflict)
                #expect(Data(response.body.readableBytesView) == upstreamError)
            }
        }
    }

    @Test func missingAndUnreachableUpstreamsExplainRecovery() async throws {
        for missingRoute in [false, true] {
            let server = InspectorServer(configuration: try .init()) { _ in
                if missingRoute {
                    return UpstreamResponse(status: 404, body: Data(#"{"error":"not found"}"#.utf8))
                }
                throw URLError(.cannotConnectToHost)
            }
            try await Application(router: server.router()).test(.router) { client in
                try await client.execute(uri: "/api/model", method: .get) { response in
                    #expect(response.status == .badGateway)
                    #expect(String(buffer: response.body).contains(missingRoute ? "inspector_unavailable" : "midnight_unreachable"))
                }
            }
        }
    }

    @Test func rejectsOversizeAndCrossOriginQuestionsBeforeForwarding() async throws {
        let server = InspectorServer(configuration: try .init()) { _ in
            Issue.record("Rejected requests must not reach Midnight")
            return UpstreamResponse(status: 200, body: Data("{}".utf8))
        }
        try await Application(router: server.router()).test(.router) { client in
            try await client.execute(
                uri: "/api/trace", method: .post, headers: [.contentType: "application/json"],
                body: .init(string: String(repeating: "x", count: InspectorServer.maximumRequestBytes + 1))
            ) { response in
                #expect(response.status == .contentTooLarge)
            }
            try await client.execute(
                uri: "/api/trace", method: .post,
                headers: [.contentType: "application/json", .origin: "https://example.com"],
                body: .init(string: "{}")
            ) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(
                uri: "/api/trace", method: .post, headers: [.contentType: "text/plain"],
                body: .init(string: "{}")
            ) { response in
                #expect(response.status == .unsupportedMediaType)
            }
        }
    }

    @Test func rejectsUnexpectedAndOversizeUpstreamResponses() async throws {
        for response in [
            UpstreamResponse(status: 302, body: Data("{}".utf8)),
            UpstreamResponse(status: 200, body: Data("<html>wrong server</html>".utf8)),
            UpstreamResponse(status: 200, body: Data(repeating: 32, count: InspectorServer.maximumResponseBytes + 1)),
        ] {
            let server = InspectorServer(configuration: try .init()) { _ in response }
            try await Application(router: server.router()).test(.router) { client in
                try await client.execute(uri: "/api/model", method: .get) { response in
                    #expect(response.status == .badGateway)
                }
            }
        }
    }

    @Test func servesOnlyBundledResources() async throws {
        let server = InspectorServer(configuration: try .init())
        try await Application(router: server.router()).test(.router) { client in
            for (path, contentType) in [
                ("/", "text/html"), ("/app.js", "text/javascript"), ("/styles.css", "text/css"),
                ("/control", "text/html"), ("/control/", "text/html"),
                ("/controls.js", "text/javascript"), ("/controls.css", "text/css"),
                ("/midnight-mark.svg", "image/svg+xml"), ("/favicon.svg", "image/svg+xml"),
            ] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType]?.hasPrefix(contentType) == true)
                    #expect(response.body.readableBytes > 0)
                }
            }
            try await client.execute(uri: "/Package.swift", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
