import Foundation
import Logging
import MCP
import AtmarkCore

/// The resident process's single owner of shared state, and the session table
/// over it.
///
/// The MCP SDK's `StatefulHTTPServerTransport` serves exactly one session and
/// rejects a second `initialize`, so several agents means several
/// `Server`+transport pairs. What must *not* be several is everything below them:
/// one `EKEventStore`, one confirm-token store, one audit log, one timeout
/// regime. That is the whole reason this process is resident, and it is why the
/// shared core lives here while only the server object, its transport, and the
/// caller's resolved capability set are per-session.
public actor ServerHost {
    public struct Configuration: Sendable {
        public var version: String
        public var endpointPath: String
        public var sessionTimeout: TimeInterval
        public var sweepInterval: TimeInterval

        public init(
            version: String = "0.1.0",
            endpointPath: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            sweepInterval: TimeInterval = 60
        ) {
            self.version = version
            self.endpointPath = endpointPath
            self.sessionTimeout = sessionTimeout
            self.sweepInterval = sweepInterval
        }
    }

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        /// The token that opened this session. A session keeps the capabilities it
        /// was created with, so it must also keep the token: otherwise a caller
        /// could open a session with a broad token and carry on using it while
        /// presenting a narrow one, and the narrowing would be cosmetic.
        let token: String
        let capabilities: Capabilities
        var lastAccessed: Date
    }

    private let configuration: Configuration
    private let tokenStore: TokenStore
    private let registry: ToolRegistry
    private let permissionProvider: any PermissionProviding
    private let logger: Logger

    /// Shared across every session. This is what the resident process is for:
    /// one confirm-token store so a token cannot be replayed on another
    /// connection, and one audit log so the trail has no gaps.
    private let confirmTokens = ConfirmTokenStore()
    private let audit: AuditLog
    private let appleScript = AppleScriptRunner()

    private var config: Config
    private var sessions: [String: Session] = [:]
    private var boundPort: Int = 0
    private var boundHost: String = "127.0.0.1"
    private var sweepTask: Task<Void, Never>?

    public init(
        config: Config,
        tokenStore: TokenStore,
        registry: ToolRegistry,
        permissionProvider: any PermissionProviding,
        configuration: Configuration = .init(),
        audit: AuditLog = AuditLog(),
        logger: Logger = Logger(label: "atmark.server")
    ) {
        self.audit = audit
        self.config = config
        self.tokenStore = tokenStore
        self.registry = registry
        self.permissionProvider = permissionProvider
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: - Lifecycle

    public func setBoundAddress(host: String, port: Int) {
        boundHost = host
        boundPort = port
    }

    public func startSweeping() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            guard let self else { return }
            let interval = self.configuration.sweepInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self.sweepExpiredSessions()
            }
        }
    }

    public func shutdown() async {
        sweepTask?.cancel()
        sweepTask = nil
        for id in sessions.keys {
            await closeSession(id)
        }
    }

    // MARK: - Request routing

    /// The validation pipeline every session's transport runs.
    ///
    /// Order matters. The bearer check is first so an unauthenticated
    /// `initialize` is refused before anything else inspects it, and the Origin
    /// check is next so a browser page on this machine cannot reach the server
    /// even while holding a leaked token.
    public func validationPipeline() -> StandardValidationPipeline {
        StandardValidationPipeline(validators: [
            AtmarkBearerValidator(store: tokenStore),
            OriginValidator.localhost(port: boundPort == 0 ? nil : boundPort),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Authenticate before routing, so an unknown token cannot probe which
        // session ids exist.
        guard let token = AtmarkBearerValidator.bearerToken(in: request),
              let identity = tokenStore.identity(for: token)
        else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"))
        }

        let sessionID = request.header("Mcp-Session-Id")

        if let sessionID, var session = sessions[sessionID] {
            guard session.token == token else {
                // Presenting a different token than the one that opened the
                // session would otherwise silently retain the original tier.
                return .error(
                    statusCode: 401,
                    .invalidRequest("Unauthorized"),
                    sessionID: nil
                )
            }
            session.lastAccessed = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)
            // Match swift-sdk 0.12.1's conformance host: a failed DELETE has not
            // terminated the SDK transport and must leave the routing entry live.
            if request.method == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        if sessionID != nil {
            // A session id we do not know: expired, swept, or from a previous run.
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Invalid or expired session ID")
            )
        }

        guard request.method == "POST", isInitialize(request) else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing Mcp-Session-Id header")
            )
        }

        return await createSession(for: request, token: token, identity: identity)
    }

    private func isInitialize(_ request: HTTPRequest) -> Bool {
        // Routing-only equivalent of swift-sdk 0.12.1's package-scoped
        // JSONRPCMessageKind. Do not decode Request<Initialize> here: the body
        // must reach StatefulHTTPServerTransport unchanged so the SDK remains
        // the sole owner of JSON-RPC and initialize parameter validation.
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] as? String == Initialize.name
        else { return false }

        if json["id"] as? String != nil { return true }
        return json["id"] as? Int != nil
    }

    // MARK: - Sessions

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSession(
        for request: HTTPRequest,
        token: String,
        identity: TokenIdentity
    ) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline(),
            logger: logger
        )

        let server = await makeServer(sessionID: sessionID, capabilities: identity.capabilities)

        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Could not start session"))
        }

        sessions[sessionID] = Session(
            server: server,
            transport: transport,
            token: token,
            capabilities: identity.capabilities,
            lastAccessed: Date()
        )

        let response = await transport.handleRequest(request)
        if case .error = response {
            await closeSession(sessionID)
        } else {
            logger.info("Session opened", metadata: [
                "session": "\(sessionID)",
                "identity": "\(identity.label)",
            ])
        }
        return response
    }

    private func makeServer(sessionID: String, capabilities: Capabilities) async -> Server {
        let server = Server(
            name: "atmark",
            version: configuration.version,
            capabilities: .init(tools: .init(listChanged: true))
        )

        // Capabilities are captured per session, so the tool list this client
        // sees is fixed to the tier of the token that opened the connection.
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return ListTools.Result(tools: []) }
            return ListTools.Result(tools: await self.visibleTools(for: capabilities))
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                throw AtmarkError(.backendUnavailable, detail: "server")
            }
            return try await self.call(params, sessionID: sessionID, capabilities: capabilities)
        }

        return server
    }

    private func visibleTools(for capabilities: Capabilities) -> [Tool] {
        registry.tools(config: config, capabilities: capabilities)
    }

    /// The context every module tool will be invoked with. Built per call so it
    /// always reflects the current config, and carrying the session so confirm
    /// tokens are bound to the connection that minted them.
    public func context(sessionID: String, capabilities: Capabilities) -> ToolContext {
        ToolContext(
            sessionID: sessionID,
            capabilities: capabilities,
            config: config,
            confirmTokens: confirmTokens,
            audit: audit,
            appleScript: appleScript
        )
    }

    private func call(
        _ params: CallTool.Parameters,
        sessionID: String,
        capabilities: Capabilities
    ) async throws -> CallTool.Result {
        // Re-check visibility at call time. The registry already hides what a
        // caller may not use, but a tool that is merely absent from a list is not
        // the same as one that refuses to run, and only the second survives a
        // client that cached an older list.
        guard visibleTools(for: capabilities).contains(where: { $0.name == params.name }) else {
            return Self.failure(AtmarkError(
                .notFound,
                detail: params.name,
                hint: "No such tool is available to this connection. Call tools/list for the current set."
            ))
        }

        switch params.name {
        case StatusTool.name:
            let permissions = await permissionProvider.currentPermissions()
            let snapshot = StatusSnapshot(
                version: configuration.version,
                host: boundHost,
                port: boundPort,
                modules: config.modules,
                sessionCount: sessions.count,
                capabilities: capabilities,
                permissions: permissions
            )
            // Bind to Value? explicitly: passing a Value directly also matches
            // the SDK's generic Codable overload, which is throwing.
            let structured: Value? = Value.pruned(snapshot.json)
            return CallTool.Result(
                content: [.text(text: "ok", annotations: nil, _meta: nil)],
                structuredContent: structured
            )
        default:
            return Self.failure(AtmarkError(.notFound, detail: params.name))
        }
    }

    /// Tool failures travel as `isError: true` with the compact error body, not as
    /// thrown protocol errors: the agent needs to read the code and the hint.
    static func failure(_ error: AtmarkError) -> CallTool.Result {
        let body = JSONValue.object([
            "error": .object([
                "code": .string(error.code.rawValue),
                "detail": error.detail.map { JSONValue.string($0) } ?? .null,
                "hint": .string(error.hint),
            ])
        ])
        let structured: Value? = Value.pruned(body)
        return CallTool.Result(
            content: [.text(text: error.description, annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: true
        )
    }

    // MARK: - Sweeping

    private func sweepExpiredSessions() async {
        let cutoff = Date().addingTimeInterval(-configuration.sessionTimeout)
        for (id, session) in sessions where session.lastAccessed < cutoff {
            logger.info("Session expired", metadata: ["session": "\(id)"])
            await closeSession(id)
        }
    }

    private func closeSession(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.transport.disconnect()
    }

    // MARK: - Introspection

    public var sessionCount: Int { sessions.count }
    public var currentConfig: Config { config }

    public func snapshot() async -> ServerSnapshot {
        let permissions = await permissionProvider.currentPermissions()
        return ServerSnapshot(
            host: boundHost,
            port: boundPort,
            sessionCount: sessions.count,
            config: config,
            permissions: permissions
        )
    }

    /// Replaces the in-memory config after validation, then tells every session
    /// whose visible tool surface changed to list tools again.
    ///
    /// Persistence remains `Config.save`'s responsibility. Keeping it out of the
    /// host lets a future Settings caller decide when to persist without giving
    /// the server actor a second source of configuration truth.
    public func updateConfig(_ newConfig: Config) async throws {
        // Validate before deriving effects or touching shared state. An invalid
        // bind must not become the config observed by existing tool calls.
        try newConfig.validate()
        guard newConfig != config else { return }

        let previousConfig = config
        let affectedSessions = sessions.compactMap { id, session -> (String, Server)? in
            let previousTools = registry.tools(
                config: previousConfig,
                capabilities: session.capabilities
            )
            let newTools = registry.tools(
                config: newConfig,
                capabilities: session.capabilities
            )
            return previousTools == newTools ? nil : (id, session.server)
        }

        config = newConfig

        // Try every affected session even if one transport has gone away. A
        // disconnected transport is no longer an active observer and must not
        // prevent the remaining clients from receiving their invalidation.
        for (id, server) in affectedSessions {
            do {
                try await server.notify(ToolListChangedNotification.message())
            } catch {
                logger.warning("Could not notify session that tools changed", metadata: [
                    "session": "\(id)",
                    "error": "\(error)",
                ])
            }
        }
    }

    public func tools(for capabilities: Capabilities) -> [Tool] {
        visibleTools(for: capabilities)
    }
}
