import Foundation
import Hummingbird
import StudioResources

struct UpstreamResponse: Sendable {
    let status: Int
    let body: Data
}

/// Upstream origins are configured at launch, never supplied by a web request.
struct InspectorServer: Sendable {
    static let maximumRequestBytes = 32 * 1024
    static let maximumResponseBytes = 8 * 1024 * 1024

    let configuration: InspectorConfiguration
    let modelControl: ModelControlManager?
    let studioJobs: StudioJobs?
    let transport: @Sendable (URLRequest) async throws -> UpstreamResponse

    init(
        configuration: InspectorConfiguration,
        modelControl: ModelControlManager? = nil,
        studioJobs: StudioJobs? = nil,
        transport: (@Sendable (URLRequest) async throws -> UpstreamResponse)? = nil
    ) {
        self.configuration = configuration
        self.modelControl = modelControl
        self.studioJobs = studioJobs
        let client = InspectorHTTPClient()
        self.transport = transport ?? { try await client.send($0) }
    }

    func router() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/prepare") { _, _ in try resource("prepare", extension: "html", type: "text/html; charset=utf-8") }
        router.get("/prepare.js") { _, _ in
            try resource("prepare", extension: "js", type: "text/javascript; charset=utf-8")
        }
        router.get("/prepare.css") { _, _ in try resource("prepare", extension: "css", type: "text/css; charset=utf-8")
        }
        router.get("/api/studio/state") { _, _ in
            guard let studioJobs else { return controlsUnavailable() }
            return try await json(studioJobs.state())
        }
        router.post("/api/studio/jobs") { request, _ in
            await studioMutation(request) { (jobs, payload: StudioJobRequest) in try await jobs.start(payload) }
        }
        router.post("/api/studio/cancel") { request, _ in
            await studioMutation(request) { (jobs, _: EmptyControlRequest) in await jobs.cancel() }
        }
        router.post("/api/studio/load-adapter") { request, _ in
            await studioMutation(request) { (jobs, payload: StudioAdapterRequest) in
                guard let modelControl else { throw ModelControlError("Model controls are unavailable.", status: 503) }
                let (profile, adapter) = try await jobs.adapterForJob(payload.jobID)
                _ = try await modelControl.load(profile, adapter: adapter)
                return await jobs.state()
            }
        }
        router.post("/api/studio/datasets") { request, _ in
            await studioMutation(request, limit: 5 * 1024 * 1024) { (jobs, payload: StudioDatasetRequest) in
                try await jobs.saveDataset(payload)
            }
        }
        router.get("/") { _, _ in try resource("index", extension: "html", type: "text/html; charset=utf-8") }
        router.get("/index.html") { _, _ in try resource("index", extension: "html", type: "text/html; charset=utf-8") }
        router.get("/app.js") { _, _ in try resource("app", extension: "js", type: "text/javascript; charset=utf-8") }
        router.get("/styles.css") { _, _ in try resource("styles", extension: "css", type: "text/css; charset=utf-8") }
        router.get("/midnight-mark.svg") { _, _ in
            try resource("midnight-mark", extension: "svg", type: "image/svg+xml")
        }
        router.get("/favicon.svg") { _, _ in try resource("favicon", extension: "svg", type: "image/svg+xml") }
        router.get("/control") { _, _ in try resource("controls", extension: "html", type: "text/html; charset=utf-8") }
        router.get("/controls.js") { _, _ in
            try resource("controls", extension: "js", type: "text/javascript; charset=utf-8")
        }
        router.get("/controls.css") { _, _ in
            try resource("controls", extension: "css", type: "text/css; charset=utf-8")
        }
        router.get("/api/connections") { _, _ in
            try await json(ConnectionsResponse(connections: currentConnections()))
        }
        router.get("/api/control/models") { _, _ in
            guard let modelControl else { return controlsUnavailable() }
            return try await json(ControlModelsResponse(models: modelControl.catalog()))
        }
        router.get("/api/control/state") { _, _ in
            guard let modelControl else { return controlsUnavailable() }
            return try await json(modelControl.state())
        }
        router.post("/api/control/profile") { request, _ in
            await controlMutation(request) { (manager, profile: ModelControlProfile) in
                try await manager.save(profile)
            }
        }
        router.post("/api/control/load") { request, _ in
            await controlMutation(request) { (manager, profile: ModelControlProfile) in
                try await manager.load(profile)
            }
        }
        router.post("/api/control/unload") { request, _ in
            await controlMutation(request) { (manager, _: EmptyControlRequest) in
                try await manager.unload()
            }
        }
        router.post("/api/control/external") { request, _ in
            await controlMutation(request) { (manager, _: EmptyControlRequest) in
                try await manager.useExternal()
            }
        }
        router.get("/api/model") { request, _ in
            await proxy(request, path: "/v1/inspector/model", body: nil)
        }
        router.post("/api/trace") { request, _ in
            guard
                request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                    .lowercased() == "application/json"
            else {
                return error(
                    status: .unsupportedMediaType, message: "Send the question as application/json.",
                    code: "invalid_content_type")
            }
            if let origin = request.headers[.origin], !allowedOrigin(origin) {
                return error(
                    status: .forbidden,
                    message: "Open Midnight Studio on its local browser address before running a trace.",
                    code: "invalid_origin")
            }
            do {
                let body = try await request.body.collect(upTo: Self.maximumRequestBytes)
                return await proxy(request, path: "/v1/inspector/trace", body: Data(body.readableBytesView))
            } catch {
                return self.error(
                    status: .contentTooLarge, message: "The question request exceeds the 32 KiB Studio limit.",
                    code: "request_too_large")
            }
        }
        return router
    }

    private func proxy(_ request: Request, path: String, body: Data?) async -> Response {
        let id = request.uri.queryParameters["connection"].map(String.init) ?? "primary"
        guard let configuredConnection = configuration.connections.first(where: { $0.id == id }) else {
            return error(
                status: .badRequest,
                message:
                    "That connection is not configured. Start Studio with --compare-url to add a comparison server.",
                code: "unknown_connection")
        }
        let routing = id == "primary" ? await modelControl?.routingState() : nil
        if let routing, routing.mode == "managed", routing.phase != "loaded" {
            let message =
                ["loading", "stopping"].contains(routing.phase)
                ? "The managed model is changing. Wait until Model controls reports it ready, then refresh the layer explorer."
                : "No managed model is ready. Load a model in Model controls or switch to the existing server, then refresh the layer explorer."
            return error(status: .conflict, message: message, code: "model_not_ready")
        }
        let connection =
            routing.map {
                InspectorConnection(
                    id: "primary", name: $0.mode == "managed" ? "Managed" : configuredConnection.name, url: $0.url)
            } ?? configuredConnection
        let url = connection.url.appendingPathComponent(path)
        var upstream = URLRequest(url: url)
        upstream.httpMethod = body == nil ? "GET" : "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Accept")
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.httpBody = body
        upstream.timeoutInterval = body == nil ? 15 : 300
        do {
            let response = try await transport(upstream)
            if await routingChanged(since: routing) { return modelChanged() }
            guard response.body.count <= Self.maximumResponseBytes else {
                return error(
                    status: .badGateway, message: "Midnight returned more inspection data than the 8 MiB Studio limit.",
                    code: "upstream_too_large")
            }
            if response.status == 404 {
                return error(
                    status: .badGateway,
                    message:
                        "\(connection.name) Midnight does not expose the Inspector API. Rebuild and restart Midnight with Inspector support.",
                    code: "inspector_unavailable")
            }
            guard (200...599).contains(response.status), !(300...399).contains(response.status),
                (try? JSONSerialization.jsonObject(with: response.body)) != nil
            else {
                return error(
                    status: .badGateway,
                    message:
                        "\(connection.name) Midnight returned an unexpected response. Check the configured server address.",
                    code: "invalid_upstream_response")
            }
            return responseData(
                response.body, status: .init(code: response.status), type: "application/json; charset=utf-8")
        } catch {
            if await routingChanged(since: routing) { return modelChanged() }
            return self.error(
                status: .badGateway,
                message:
                    "Cannot reach \(connection.name.lowercased()) Midnight at \(connection.url.absoluteString). Start that server, then reconnect. \(error.localizedDescription)",
                code: "midnight_unreachable")
        }
    }

    private func routingChanged(since previous: ModelControlRoutingState?) async -> Bool {
        guard let previous, let current = await modelControl?.routingState() else { return false }
        return current.revision != previous.revision || current.mode != previous.mode
            || (previous.mode == "managed" && current.phase != "loaded")
    }

    private func modelChanged() -> Response {
        error(
            status: .conflict,
            message:
                "The selected model changed while this request was running. Refresh the layer explorer before trying again.",
            code: "model_changed")
    }

    private func currentConnections() async -> [InspectorConnection] {
        guard let managedURL = await modelControl?.activeManagedURL() else { return configuration.connections }
        return configuration.connections.map { connection in
            connection.id == "primary"
                ? InspectorConnection(id: "primary", name: "Managed", url: managedURL)
                : connection
        }
    }

    private func controlMutation<Payload: Decodable & Sendable>(
        _ request: Request,
        action: @Sendable (ModelControlManager, Payload) async throws -> ModelControlState
    ) async -> Response {
        guard
            request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                .lowercased() == "application/json"
        else {
            return error(
                status: .unsupportedMediaType, message: "Send model controls as application/json.",
                code: "invalid_content_type")
        }
        if let origin = request.headers[.origin], !allowedOrigin(origin) {
            return error(
                status: .forbidden, message: "Open model controls on the Inspector's local browser address.",
                code: "invalid_origin")
        }
        guard let modelControl else { return controlsUnavailable() }
        let data: Data
        do {
            let body = try await request.body.collect(upTo: Self.maximumRequestBytes)
            data = Data(body.readableBytesView)
        } catch {
            return self.error(
                status: .contentTooLarge, message: "The model control request exceeds the 32 KiB limit.",
                code: "request_too_large")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return self.error(
                status: .badRequest, message: "Send a complete model profile with valid JSON field types.",
                code: "invalid_request")
        }
        do {
            return try await json(action(modelControl, payload))
        } catch let controlError as ModelControlError {
            return self.error(
                status: .init(code: controlError.status), message: controlError.message, code: controlError.code)
        } catch {
            return self.error(
                status: .internalServerError,
                message: "The model control operation failed: \(error.localizedDescription)", code: "control_failed")
        }
    }

    private func controlsUnavailable() -> Response {
        error(
            status: .serviceUnavailable, message: "Model controls are not enabled in this Inspector instance.",
            code: "controls_unavailable")
    }

    private func studioMutation<Payload: Decodable & Sendable>(
        _ request: Request, limit: Int = 32 * 1024,
        action: @Sendable (StudioJobs, Payload) async throws -> StudioState
    ) async -> Response {
        guard
            request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                .lowercased() == "application/json"
        else {
            return error(
                status: .unsupportedMediaType, message: "Send Studio requests as application/json.",
                code: "invalid_content_type")
        }
        if let origin = request.headers[.origin], !allowedOrigin(origin) {
            return error(
                status: .forbidden, message: "Open Studio at its local browser address.", code: "invalid_origin")
        }
        guard let studioJobs else { return controlsUnavailable() }
        let data: Data
        do { data = Data(try await request.body.collect(upTo: limit).readableBytesView) } catch {
            return self.error(
                status: .contentTooLarge, message: "Studio request exceeds its size limit.", code: "request_too_large")
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
            return self.error(
                status: .badRequest, message: "Send complete Studio settings with valid JSON field types.",
                code: "invalid_request")
        }
        do { return try await json(action(studioJobs, payload)) } catch let issue as ModelControlError {
            return error(status: .init(code: issue.status), message: issue.message, code: issue.code)
        } catch {
            return self.error(status: .internalServerError, message: error.localizedDescription, code: "studio_error")
        }
    }

    private func allowedOrigin(_ raw: String) -> Bool {
        guard let origin = URLComponents(string: raw) else { return false }
        return origin.scheme == "http" && ["127.0.0.1", "localhost"].contains(origin.host ?? "")
            && (origin.port ?? 80) == configuration.port
            && origin.user == nil && origin.password == nil && origin.path.isEmpty
            && origin.query == nil && origin.fragment == nil
    }

    private func resource(_ name: String, extension suffix: String, type: String) throws -> Response {
        guard let url = StudioResourceBundle.bundle.url(forResource: name, withExtension: suffix) else {
            return error(status: .notFound, message: "Inspector resource not found.", code: "resource_not_found")
        }
        var response = responseData(try Data(contentsOf: url), status: .ok, type: type)
        response.headers[.contentSecurityPolicy] =
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        return response
    }

    private func json<Value: Encodable>(_ value: Value) throws -> Response {
        responseData(try JSONEncoder().encode(value), status: .ok, type: "application/json; charset=utf-8")
    }

    private func error(status: HTTPResponse.Status, message: String, code: String) -> Response {
        let body = (try? JSONEncoder().encode(ErrorEnvelope(error: .init(message: message, code: code)))) ?? Data()
        return responseData(body, status: status, type: "application/json; charset=utf-8")
    }

    private func responseData(_ data: Data, status: HTTPResponse.Status, type: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: type, .cacheControl: "no-store", .xContentTypeOptions: "nosniff"],
            body: .init(byteBuffer: .init(bytes: data))
        )
    }
}

private struct ConnectionsResponse: Encodable {
    let connections: [InspectorConnection]
}

private struct ControlModelsResponse: Encodable {
    let models: [ModelControlModel]
}

private struct EmptyControlRequest: Decodable, Sendable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected an empty JSON object."))
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }
        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

private struct ErrorEnvelope: Encodable {
    struct Detail: Encodable {
        let message: String
        let code: String
    }
    let error: Detail
}

struct InspectorHTTPClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func authorized(
        _ request: URLRequest, apiKey: String? = ProcessInfo.processInfo.environment["MIDNIGHT_API_KEY"]
    ) -> URLRequest {
        var request = request
        if request.value(forHTTPHeaderField: "Authorization") == nil, let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> UpstreamResponse {
        let request = Self.authorized(request)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConfigurationError("The upstream response was not HTTP.")
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < InspectorServer.maximumResponseBytes else {
                throw ConfigurationError("The upstream response exceeded the 8 MiB limit.")
            }
            body.append(byte)
        }
        return UpstreamResponse(status: response.statusCode, body: body)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
