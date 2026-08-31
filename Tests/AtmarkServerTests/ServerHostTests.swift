import Foundation
import MCP
import AtmarkCore
import Testing

@testable import AtmarkServer

@Suite("ServerHost routing and session binding")
struct ServerHostTests {
    private static let broadToken = "broad-token"
    private static let narrowToken = "narrow-token"
    private static let permissions = PermissionSnapshot(
        reminders: .notDetermined,
        mailAutomation: .unavailable,
        fullDiskAccess: .denied
    )

    private struct TestPermissionProvider: PermissionProviding {
        let snapshot: PermissionSnapshot

        func currentPermissions() async -> PermissionSnapshot { snapshot }
    }

    private actor PassiveBoundaryProvider: PermissionProviding, PermissionActionPerforming {
        var reads = 0
        var actions: [PermissionAction] = []

        func currentPermissions() async -> PermissionSnapshot {
            reads += 1
            return ServerHostTests.permissions
        }

        func perform(_ action: PermissionAction) async throws {
            actions.append(action)
        }
    }

    private func makeHost(
        config: Config = Config(),
        registry: ToolRegistry = ProductionToolCatalogue.registry,
        permissionProvider: (any PermissionProviding)? = nil
    ) -> ServerHost {
        ServerHost(
            config: config,
            tokenStore: TokenStore([
                Self.broadToken: TokenIdentity(label: "local", capabilities: .all),
                Self.narrowToken: TokenIdentity(label: "remote", capabilities: .readOnly),
            ]),
            registry: registry,
            permissionProvider: permissionProvider
                ?? TestPermissionProvider(snapshot: Self.permissions)
        )
    }

    private func request(
        method: String = "POST",
        token: String?,
        sessionID: String? = nil,
        origin: String? = nil,
        body: String? = Self.initializeBody
    ) -> HTTPRequest {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        if let origin { headers["Origin"] = origin }
        return HTTPRequest(
            method: method,
            headers: headers,
            body: body.map { Data($0.utf8) },
            path: "/mcp"
        )
    }

    private static let initializeBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
    private static let initializedBody = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

    /// Case-insensitive: HTTPResponse.headers is a plain dictionary, and the SDK
    /// spells the header "MCP-Session-Id" while the spec is case-agnostic.
    private func sessionID(of response: HTTPResponse) -> String? {
        response.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
    }

    private func openSession(on host: ServerHost, token: String) async throws -> String {
        let response = await host.handle(request(token: token))
        return try #require(sessionID(of: response))
    }

    private func completeInitialization(on host: ServerHost, token: String) async throws -> String {
        let sessionID = try await openSession(on: host, token: token)
        let response = await host.handle(
            request(token: token, sessionID: sessionID, body: Self.initializedBody)
        )
        #expect(response.statusCode == 202)
        return sessionID
    }

    private func notificationStream(
        on host: ServerHost,
        token: String,
        sessionID: String
    ) async -> AsyncThrowingStream<Data, Swift.Error>? {
        let response = await host.handle(
            request(method: "GET", token: token, sessionID: sessionID, body: nil)
        )
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected a standalone SSE stream")
            return nil
        }
        return stream
    }

    private func text(in stream: AsyncThrowingStream<Data, Swift.Error>) async throws -> String {
        var chunks: [Data] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    @Test("a request with no token is refused before routing")
    func noTokenIsRefused() async {
        let response = await makeHost().handle(request(token: nil))
        #expect(response.statusCode == 401)
    }

    @Test("an unknown token is refused")
    func unknownTokenIsRefused() async {
        let response = await makeHost().handle(request(token: "nope"))
        #expect(response.statusCode == 401)
    }

    @Test("initialize opens a session and returns its id")
    func initializeOpensSession() async throws {
        let host = makeHost()
        let sessionID = try await openSession(on: host, token: Self.broadToken)
        #expect(!sessionID.isEmpty)
        #expect(await host.sessionCount == 1)
    }

    @Test("initialize without a request id is rejected before session creation")
    func initializeWithoutIDDoesNotOpenSession() async {
        let host = makeHost()
        let response = await host.handle(
            request(
                token: Self.broadToken,
                body: #"{"jsonrpc":"2.0","method":"initialize","params":{}}"#
            )
        )

        #expect(response.statusCode == 400)
        #expect(sessionID(of: response) == nil)
        #expect(
            String(decoding: response.bodyData ?? Data(), as: UTF8.self)
                .contains("Missing Mcp-Session-Id header")
        )
        #expect(await host.sessionCount == 0)
    }

    @Test("initialize routing leaves malformed parameters for the SDK to validate")
    func malformedInitializeParametersReachSDK() async throws {
        let host = makeHost()
        let response = await host.handle(
            request(
                token: Self.broadToken,
                body: #"{"jsonrpc":"2.0","id":"route-me","method":"initialize","params":[]}"#
            )
        )

        let openedSessionID = try #require(sessionID(of: response))
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected the SDK transport to stream its protocol response")
            return
        }

        let responseText = try await text(in: stream)
        #expect(responseText.contains(#""id":"route-me""#))
        #expect(responseText.contains(#""error""#))
        #expect(await host.sessionCount == 1)
        #expect(!openedSessionID.isEmpty)
        await host.shutdown()
    }

    @Test("two clients are served by one host")
    func twoConcurrentSessions() async throws {
        let host = makeHost()
        let first = try await openSession(on: host, token: Self.broadToken)
        let second = try await openSession(on: host, token: Self.narrowToken)

        #expect(first != second)
        // One process, one shared core, two sessions — the property the resident
        // architecture exists for (A4).
        #expect(await host.sessionCount == 2)
    }

    @Test("a session cannot be driven with a different token than opened it")
    func sessionIsBoundToItsToken() async throws {
        let host = makeHost()
        let sessionID = try await openSession(on: host, token: Self.broadToken)

        // Without this, a caller could open with a broad token and continue with a
        // narrow one while silently retaining the broad tier — making the
        // narrowing cosmetic, which is precisely what batch four's remote
        // read-only token must not be.
        let response = await host.handle(
            request(token: Self.narrowToken, sessionID: sessionID, body: nil))
        #expect(response.statusCode == 401)
    }

    @Test("an unknown session id is 404, not a new session")
    func unknownSessionIsNotFound() async {
        let response = await makeHost().handle(
            request(token: Self.broadToken, sessionID: "no-such-session", body: nil))
        #expect(response.statusCode == 404)
    }

    @Test("a non-initialize POST without a session is refused")
    func nonInitializeWithoutSession() async {
        let response = await makeHost().handle(
            request(token: Self.broadToken, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        #expect(response.statusCode == 400)
    }

    @Test("only a successful DELETE closes the session")
    func onlySuccessfulDeleteClosesSession() async throws {
        let host = makeHost()
        let sessionID = try await openSession(on: host, token: Self.broadToken)
        #expect(await host.sessionCount == 1)

        let failedRequest = request(
            method: "DELETE",
            token: Self.broadToken,
            sessionID: sessionID,
            origin: "https://example.com",
            body: nil
        )
        let failedResponse = await host.handle(failedRequest)

        #expect(failedResponse.statusCode == 403)
        #expect(await host.sessionCount == 1)

        let successfulResponse = await host.handle(
            request(
                method: "DELETE",
                token: Self.broadToken,
                sessionID: sessionID,
                body: nil
            )
        )
        #expect(successfulResponse.statusCode == 200)
        #expect(await host.sessionCount == 0)
    }

    @Test("capabilities are resolved from the token that opened the session")
    func capabilitiesFollowTheToken() async {
        let host = makeHost()
        #expect(await host.tools(for: .all).map(\.name) == ["atmark_status"])
        #expect(await host.tools(for: []).isEmpty)
    }

    @Test("live snapshot uses the injected permission provider")
    func snapshotUsesInjectedPermissions() async {
        let snapshot = await makeHost().snapshot()

        #expect(snapshot.permissions == Self.permissions)
        #expect(snapshot.config == Config())
        #expect(snapshot.sessionCount == 0)
    }

    @Test("atmark_status uses only the passive permission boundary")
    func statusToolDoesNotPerformPermissionActions() async throws {
        let provider = PassiveBoundaryProvider()
        let host = makeHost(permissionProvider: provider)
        let sessionID = try await completeInitialization(on: host, token: Self.broadToken)
        let response = await host.handle(
            request(
                token: Self.broadToken,
                sessionID: sessionID,
                body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"atmark_status","arguments":{}}}"#
            )
        )
        guard case .stream(let stream, _) = response else {
            Issue.record("Expected a streamed tool response")
            return
        }

        let responseText = try await text(in: stream)

        #expect(responseText.contains("not_determined"))
        #expect(await provider.reads == 1)
        #expect(await provider.actions.isEmpty)
        await host.shutdown()
    }

    @Test("a valid config change is visible to the shared core")
    func configUpdateIsShared() async throws {
        let host = makeHost()
        try await host.updateConfig(
            Config(modules: ["reminders": .init(enabled: false, writes: false)])
        )
        // Shared, not per-session: both connected clients read the same config.
        #expect(await host.currentConfig.modules["reminders"]?.enabled == false)
    }

    @Test("an invalid config is rejected before shared state changes")
    func invalidConfigDoesNotMutateState() async {
        let host = makeHost()
        let original = await host.currentConfig
        var invalid = original
        invalid.http.bind = "0.0.0.0"

        await #expect(throws: AtmarkError.self) {
            try await host.updateConfig(invalid)
        }
        #expect(await host.currentConfig == original)
    }

    @Test("a tool-surface change notifies every affected active session over SDK transport")
    func configUpdateEmitsListChanged() async throws {
        let initialConfig = Config(modules: [
            "reminders": .init(enabled: true, writes: false),
            "mail": .init(enabled: true, writes: false),
        ])
        let host = makeHost(config: initialConfig, registry: SyntheticToolCatalogue.registry)

        let firstBroadID = try await completeInitialization(on: host, token: Self.broadToken)
        let secondBroadID = try await completeInitialization(on: host, token: Self.broadToken)
        let narrowID = try await completeInitialization(on: host, token: Self.narrowToken)

        let firstBroadStream = try #require(
            await notificationStream(on: host, token: Self.broadToken, sessionID: firstBroadID)
        )
        let secondBroadStream = try #require(
            await notificationStream(on: host, token: Self.broadToken, sessionID: secondBroadID)
        )
        let narrowStream = try #require(
            await notificationStream(on: host, token: Self.narrowToken, sessionID: narrowID)
        )

        var updatedConfig = initialConfig
        updatedConfig.modules["reminders"]?.writes = true
        try await host.updateConfig(updatedConfig)

        #expect(
            await host.tools(for: .all).map(\.name).contains("atmark_reminders_create")
        )
        #expect(
            await host.tools(for: .readOnly).map(\.name).contains("atmark_reminders_create") == false
        )

        // Closing the transports finishes their SSE streams, letting the test
        // inspect every buffered event without sleeps or timing assumptions.
        await host.shutdown()
        let firstBroadText = try await text(in: firstBroadStream)
        let secondBroadText = try await text(in: secondBroadStream)
        let narrowText = try await text(in: narrowStream)

        #expect(firstBroadText.contains(ToolListChangedNotification.name))
        #expect(secondBroadText.contains(ToolListChangedNotification.name))
        #expect(narrowText.contains(ToolListChangedNotification.name) == false)
    }
}
