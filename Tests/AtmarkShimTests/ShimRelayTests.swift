import Foundation
import MCP
import Testing

@testable import AtmarkShim

@Suite("Shim transport relay", .serialized)
struct ShimRelayTests {
    fileprivate static let credential = "test-only-relay-bearer"
    fileprivate static let sessionID = "test-session"
    fileprivate static let initialize = Data(#"{"jsonrpc":"2.0", "id":1,"method":"initialize"}"#.utf8)
    fileprivate static let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)

    @Test("payload bytes, session reuse, 202 silence, JSON response, and normal DELETE")
    func payloadSessionAndTermination() async throws {
        await MockURLProtocol.storage.clear()
        let request = Data(#"{"jsonrpc":"2.0", "id":2,"method":"tools/list"}"#.utf8)
        let initializeResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8)
        let listResponse = Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.utf8)
        let observer = RelayObserver(expectedBodies: [Self.initialize, Self.initialized, request])

        await MockURLProtocol.storage.set { urlRequest in
            await observer.response(
                for: urlRequest,
                initializeResponse: initializeResponse,
                requestResponse: listResponse
            )
        }

        let harness = try PipeHarness()
        let relay = makeRelay(harness: harness)
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize, Self.initialized, request])
        harness.closeInput()
        try await relayTask.value

        let output = try harness.finishOutputAndReadRemaining()
        var expected = initializeResponse
        expected.append(UInt8(ascii: "\n"))
        expected.append(listResponse)
        expected.append(UInt8(ascii: "\n"))
        #expect(output == expected)

        let snapshot = await observer.snapshot()
        #expect(snapshot.bodiesPreserved)
        #expect(snapshot.allRequestsAuthenticated)
        #expect(snapshot.sessionReused)
        #expect(snapshot.deleteCount == 1)
        #expect(snapshot.deleteAuthenticated)
        #expect(snapshot.deleteUsedSession)
    }

    @Test("POST SSE suppresses priming and preserves multi-event split chunks")
    func postSSEMultiEventSplitChunks() async throws {
        await MockURLProtocol.storage.clear()
        let first = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"first"}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2,"result":{"text":"café"}}"#.utf8)
        let eventBytes = Data(
            (": priming\n\nid: one\ndata: " + String(decoding: first, as: UTF8.self)
                + "\n\nid: two\ndata: " + String(decoding: second, as: UTF8.self) + "\n\n").utf8
        )
        // One byte per URLProtocol delivery forces the SDK's SSE parser to
        // preserve state across framing boundaries, including the two-byte UTF-8
        // encoding of "é".
        let chunks = eventBytes.map { Data([$0]) }

        await MockURLProtocol.storage.set { request in
            if request.shimTestBody() == Self.initialize {
                return MockHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "text/event-stream",
                        HTTPHeaderName.sessionID: Self.sessionID,
                    ],
                    chunks: chunks
                )
            }
            return MockHTTPResponse(statusCode: 202)
        }

        let harness = try PipeHarness()
        let relay = makeRelay(harness: harness)
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize])
        let frames = try await harness.readFrames(count: 2)
        #expect(frames == [first, second])

        try harness.write(frames: [Self.initialized])
        harness.closeInput()
        try await relayTask.value
        let remaining = try harness.finishOutputAndReadRemaining()
        #expect(remaining.isEmpty)
    }

    @Test("a held POST does not block cancellation or another request")
    func heldPostDoesNotBlockLaterPosts() async throws {
        await MockURLProtocol.storage.clear()
        let held = Data(#"{"jsonrpc":"2.0","id":10,"method":"tools/call"}"#.utf8)
        let cancelled = Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":10}}"#.utf8)
        let another = Data(#"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#.utf8)
        let initializeResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8)
        let anotherResponse = Data(#"{"jsonrpc":"2.0","id":11,"result":{"tools":[]}}"#.utf8)
        let gate = AsyncGate()
        let observer = ConcurrentObserver(held: held, cancelled: cancelled, another: another)

        await MockURLProtocol.storage.set { request in
            let body = request.shimTestBody()
            if body == Self.initialize {
                return MockHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        HTTPHeaderName.sessionID: Self.sessionID,
                    ],
                    chunks: [initializeResponse]
                )
            }
            if body == Self.initialized {
                return MockHTTPResponse(statusCode: 202)
            }
            return await observer.response(
                for: request,
                body: body,
                gate: gate,
                anotherResponse: anotherResponse
            )
        }

        let harness = try PipeHarness()
        let relay = makeRelay(harness: harness, maximumConcurrentPosts: 3)
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize, Self.initialized, held, cancelled, another])

        let postedConcurrently = await eventually {
            await observer.sawHeldCancellationAndAnother()
        }
        let framesResult: Result<[Data], Error>
        do {
            framesResult = .success(
                try await harness.readFrames(count: 2, timeoutMilliseconds: 500)
            )
        } catch {
            framesResult = .failure(error)
        }

        await gate.open()
        harness.closeInput()
        try await relayTask.value
        _ = try harness.finishOutputAndReadRemaining()

        #expect(postedConcurrently)
        let framesMatch: Bool
        switch framesResult {
        case .success(let frames):
            framesMatch = frames == [initializeResponse, anotherResponse]
        case .failure:
            framesMatch = false
        }
        #expect(framesMatch)
    }

    @Test("POST queue never starts more requests than its configured limit")
    func postQueueLimit() async throws {
        await MockURLProtocol.storage.clear()
        let initializeResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let response = Data(#"{"jsonrpc":"2.0","id":10,"result":{}}"#.utf8)
        let requests = (10..<14).map {
            Data(#"{"jsonrpc":"2.0","id":\#($0),"method":"tools/list"}"#.utf8)
        }
        let gate = AsyncGate()
        let started = LockedCounter()

        await MockURLProtocol.storage.set { request in
            let body = request.shimTestBody()
            if body == Self.initialize {
                return MockHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        HTTPHeaderName.sessionID: Self.sessionID,
                    ],
                    chunks: [initializeResponse]
                )
            }
            if body == Self.initialized || request.httpMethod == "DELETE" {
                return MockHTTPResponse(statusCode: request.httpMethod == "DELETE" ? 200 : 202)
            }
            started.increment()
            return MockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [response],
                pauseBeforeFinish: gate
            )
        }

        let harness = try PipeHarness()
        let relay = makeRelay(harness: harness, maximumConcurrentPosts: 2)
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize, Self.initialized] + requests)

        #expect(await eventually { started.get() == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(started.get() == 2)

        await gate.open()
        #expect(await eventually { started.get() == requests.count })
        harness.closeInput()
        try await relayTask.value
        _ = try harness.finishOutputAndReadRemaining()
    }

    @Test("stdin EOF has a bounded grace period for a stuck POST")
    func stuckPostDoesNotBlockEOF() async throws {
        await MockURLProtocol.storage.clear()
        let held = Data(#"{"jsonrpc":"2.0","id":10,"method":"tools/call"}"#.utf8)
        let initializeResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let gate = AsyncGate()
        let heldStarted = LockedFlag(false)

        await MockURLProtocol.storage.set { request in
            let body = request.shimTestBody()
            if body == Self.initialize {
                return MockHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        HTTPHeaderName.sessionID: Self.sessionID,
                    ],
                    chunks: [initializeResponse]
                )
            }
            if body == Self.initialized || request.httpMethod == "DELETE" {
                return MockHTTPResponse(statusCode: request.httpMethod == "DELETE" ? 200 : 202)
            }
            heldStarted.set(true)
            return MockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(": held\n\n".utf8)],
                pauseBeforeFinish: gate
            )
        }

        let harness = try PipeHarness()
        let relay = makeRelay(
            harness: harness,
            shutdownDrainTimeout: .milliseconds(20)
        )
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize, Self.initialized, held])
        #expect(await eventually { heldStarted.get() })

        let clock = ContinuousClock()
        let start = clock.now
        harness.closeInput()
        try await relayTask.value
        let elapsed = start.duration(to: clock.now)
        await gate.open()
        _ = try harness.finishOutputAndReadRemaining()

        #expect(elapsed < .milliseconds(500))
    }

    @Test("runtime resident death terminates an otherwise idle relay")
    func runtimeResidentDeath() async throws {
        await MockURLProtocol.storage.clear()
        let initializeResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        await MockURLProtocol.storage.set { request in
            MockHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    HTTPHeaderName.sessionID: Self.sessionID,
                ],
                chunks: [initializeResponse]
            )
        }

        let alive = LockedFlag(true)
        let harness = try PipeHarness()
        let relay = makeRelay(
            harness: harness,
            livenessInterval: .milliseconds(10),
            processIsAlive: { _ in alive.get() }
        )
        let relayTask = Task { try await relay.run() }
        try harness.write(frames: [Self.initialize])
        _ = try await harness.readFrames(count: 1)
        alive.set(false)

        let failure: ShimFailure?
        do {
            try await relayTask.value
            failure = nil
        } catch let caught as ShimFailure {
            failure = caught
        }
        harness.closeInput()
        _ = try harness.finishOutputAndReadRemaining()
        #expect(failure == .residentStopped)
    }

    @Test("HTTP authentication and connection failures are mapped without response leakage")
    func httpFailures() async throws {
        for (status, transportError, expected) in [
            (401, false, ShimFailure.authenticationFailed),
            (0, true, ShimFailure.connectionFailed),
        ] {
            await MockURLProtocol.storage.clear()
            await MockURLProtocol.storage.set { _ in
                if transportError { throw URLError(.cannotConnectToHost) }
                return MockHTTPResponse(statusCode: status)
            }

            let harness = try PipeHarness()
            let relay = makeRelay(harness: harness)
            let relayTask = Task { try await relay.run() }
            try harness.write(frames: [Self.initialize])

            let failure: ShimFailure?
            do {
                try await relayTask.value
                failure = nil
            } catch let caught as ShimFailure {
                failure = caught
            }
            harness.closeInput()
            _ = try harness.finishOutputAndReadRemaining()
            #expect(failure == expected)
        }
    }

    private func makeRelay(
        harness: PipeHarness,
        maximumConcurrentPosts: Int = 4,
        livenessInterval: Duration = .seconds(1),
        shutdownDrainTimeout: Duration = .seconds(2),
        processIsAlive: @escaping @Sendable (Int32) -> Bool = { _ in true }
    ) -> ShimRelay {
        ShimRelay(
            endpoint: ShimEndpoint(
                port: 51_234,
                host: "127.0.0.1",
                token: Self.credential,
                pid: 42
            ),
            stdio: harness.shimTransport,
            urlSessionConfiguration: .shimMock,
            streaming: false,
            configuration: .init(
                maximumConcurrentPosts: maximumConcurrentPosts,
                livenessInterval: livenessInterval,
                shutdownDrainTimeout: shutdownDrainTimeout
            ),
            processIsAlive: processIsAlive
        )
    }
}

private actor RelayObserver {
    struct Snapshot: Sendable {
        let bodiesPreserved: Bool
        let allRequestsAuthenticated: Bool
        let sessionReused: Bool
        let deleteCount: Int
        let deleteAuthenticated: Bool
        let deleteUsedSession: Bool
    }

    private let expectedBodies: [Data]
    private var bodies: [Data] = []
    private var authenticationChecks: [Bool] = []
    private var sessionChecks: [Bool] = []
    private var deleteCount = 0
    private var deleteAuthenticated = false
    private var deleteUsedSession = false

    init(expectedBodies: [Data]) {
        self.expectedBodies = expectedBodies
    }

    func response(
        for request: URLRequest,
        initializeResponse: Data,
        requestResponse: Data
    ) -> MockHTTPResponse {
        let authenticated = request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(ShimRelayTests.credential)"
        authenticationChecks.append(authenticated)

        if request.httpMethod == "DELETE" {
            deleteCount += 1
            deleteAuthenticated = authenticated
            deleteUsedSession = request.value(forHTTPHeaderField: HTTPHeaderName.sessionID)
                == ShimRelayTests.sessionID
            return MockHTTPResponse(statusCode: 200)
        }

        let body = request.shimTestBody()
        bodies.append(body)
        if bodies.count > 1 {
            sessionChecks.append(
                request.value(forHTTPHeaderField: HTTPHeaderName.sessionID)
                    == ShimRelayTests.sessionID
            )
        }

        if body == ShimRelayTests.initialize {
            return MockHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    HTTPHeaderName.sessionID: ShimRelayTests.sessionID,
                ],
                chunks: [initializeResponse]
            )
        }
        if body == ShimRelayTests.initialized {
            return MockHTTPResponse(statusCode: 202)
        }
        return MockHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            chunks: [requestResponse]
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            bodiesPreserved: bodies == expectedBodies,
            allRequestsAuthenticated: authenticationChecks.allSatisfy { $0 },
            sessionReused: sessionChecks.allSatisfy { $0 },
            deleteCount: deleteCount,
            deleteAuthenticated: deleteAuthenticated,
            deleteUsedSession: deleteUsedSession
        )
    }
}

private actor ConcurrentObserver {
    private let held: Data
    private let cancelled: Data
    private let another: Data
    private var seen: Set<Data> = []

    init(held: Data, cancelled: Data, another: Data) {
        self.held = held
        self.cancelled = cancelled
        self.another = another
    }

    func response(
        for request: URLRequest,
        body: Data,
        gate: AsyncGate,
        anotherResponse: Data
    ) -> MockHTTPResponse {
        seen.insert(body)
        if body == held {
            return MockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data(": held\n\n".utf8)],
                pauseBeforeFinish: gate
            )
        }
        if body == cancelled {
            return MockHTTPResponse(statusCode: 202)
        }
        if body == another {
            return MockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [anotherResponse]
            )
        }
        return MockHTTPResponse(statusCode: 500)
    }

    func sawHeldCancellationAndAnother() -> Bool {
        seen.contains(held) && seen.contains(cancelled) && seen.contains(another)
    }
}
