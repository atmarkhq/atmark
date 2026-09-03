import Foundation
import MCP

struct ShimRelay {
    struct Configuration: Sendable {
        var maximumConcurrentPosts = 4
        var livenessInterval: Duration = .seconds(1)
        var shutdownDrainTimeout: Duration = .seconds(2)
    }

    private let endpoint: ShimEndpoint
    private let stdio: StdioTransport
    private let http: HTTPClientTransport
    private let terminator: SessionTerminator
    private let configuration: Configuration
    private let processIsAlive: @Sendable (Int32) -> Bool

    init(
        endpoint: ShimEndpoint,
        stdio: StdioTransport,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
        streaming: Bool = true,
        configuration: Configuration = .init(),
        processIsAlive: @escaping @Sendable (Int32) -> Bool = EndpointResolver.defaultProcessIsAlive
    ) {
        self.endpoint = endpoint
        self.stdio = stdio
        self.configuration = configuration
        self.processIsAlive = processIsAlive

        let token = endpoint.token
        self.http = HTTPClientTransport(
            endpoint: endpoint.url!,
            configuration: urlSessionConfiguration,
            streaming: streaming,
            sseInitializationTimeout: 5,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            },
            logger: nil
        )
        self.terminator = SessionTerminator(
            endpoint: endpoint.url!,
            token: token,
            configuration: urlSessionConfiguration
        )
    }

    func run() async throws {
        do {
            try await stdio.connect()
        } catch {
            throw ShimFailure.stdioConnectionFailed
        }

        do {
            try await http.connect()
        } catch {
            await stdio.disconnect()
            throw ShimFailure.connectionFailed
        }

        let queue = HTTPPostQueue(
            http: http,
            maximumConcurrentPosts: configuration.maximumConcurrentPosts
        )
        let failureStream = queue.failures
        let pid = endpoint.pid
        let livenessInterval = configuration.livenessInterval
        let processIsAlive = processIsAlive
        let terminator = terminator

        try await withThrowingTaskGroup(of: RelayEvent.self) { group in
            group.addTask {
                try await pumpInput(stdio: stdio, http: http, queue: queue)
            }
            group.addTask {
                try await pumpOutput(http: http, stdio: stdio)
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: livenessInterval)
                    guard processIsAlive(pid) else {
                        throw ShimFailure.residentStopped
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                for await failure in failureStream {
                    throw failure
                }
                throw CancellationError()
            }

            let event: RelayEvent
            do {
                event = try await group.next() ?? .auxiliaryEnded
            } catch {
                group.cancelAll()
                await queue.cancelAll()
                await http.disconnect()
                await stdio.disconnect()
                throw Self.relayFailure(for: error)
            }

            guard event == .inputEOF else {
                group.cancelAll()
                await queue.cancelAll()
                await http.disconnect()
                await stdio.disconnect()
                throw ShimFailure.connectionFailed
            }

            let drained: Bool
            do {
                drained = try await waitForQueueDrain(
                    queue,
                    timeout: configuration.shutdownDrainTimeout
                )
            } catch {
                group.cancelAll()
                await queue.cancelAll()
                await http.disconnect()
                await stdio.disconnect()
                throw Self.relayFailure(for: error)
            }

            if !drained {
                await queue.cancelAll()
            }

            let sessionID = await http.sessionID
            if let sessionID {
                await terminator.terminate(sessionID: sessionID)
            }
            await http.disconnect()

            if drained {
                do {
                    guard try await group.next() == .outputEnded else {
                        throw ShimFailure.connectionFailed
                    }
                } catch {
                    group.cancelAll()
                    await queue.cancelAll()
                    await stdio.disconnect()
                    throw Self.relayFailure(for: error)
                }
            }

            group.cancelAll()
            await queue.cancelAll()
            await stdio.disconnect()
        }
    }

    private static func relayFailure(for error: Error) -> ShimFailure {
        if let failure = error as? ShimFailure {
            return failure
        }
        return .connectionFailed
    }
}

private enum RelayEvent: Equatable, Sendable {
    case inputEOF
    case outputEnded
    case auxiliaryEnded
}

private func waitForQueueDrain(
    _ queue: HTTPPostQueue,
    timeout: Duration
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while true {
        switch await queue.drainState() {
        case .drained:
            return true
        case .failed(let failure):
            throw failure
        case .pending:
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: min(.milliseconds(10), clock.now.duration(to: deadline)))
        }
    }
}

private func pumpInput(
    stdio: StdioTransport,
    http: HTTPClientTransport,
    queue: HTTPPostQueue
) async throws -> RelayEvent {
    let stream = await stdio.receive()
    var frameIndex = 0

    do {
        for try await frame in stream {
            if frameIndex < 2 {
                // The first response establishes the MCP session; the following
                // initialized notification must also reach the server before any
                // later call is allowed to race it. No JSON-RPC parsing is needed.
                try await http.send(frame)
            } else {
                try await queue.submit(frame)
            }
            frameIndex += 1
        }
        return .inputEOF
    } catch let failure as ShimFailure {
        throw failure
    } catch {
        throw ShimFailure.httpFailure(for: error)
    }
}

private func pumpOutput(
    http: HTTPClientTransport,
    stdio: StdioTransport
) async throws -> RelayEvent {
    let stream = await http.receive()
    do {
        for try await frame in stream {
            do {
                try await stdio.send(frame)
            } catch {
                throw ShimFailure.stdioOutputFailed
            }
        }
    } catch let failure as ShimFailure {
        throw failure
    } catch {
        if Task.isCancelled { throw CancellationError() }
        throw ShimFailure.connectionFailed
    }

    if Task.isCancelled { throw CancellationError() }
    return .outputEnded
}

private actor HTTPPostQueue {
    enum DrainState: Sendable {
        case pending
        case drained
        case failed(ShimFailure)
    }

    nonisolated let failures: AsyncStream<ShimFailure>

    private let http: HTTPClientTransport
    private let maximumConcurrentPosts: Int
    private let failureContinuation: AsyncStream<ShimFailure>.Continuation
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var slotWaiters: [CheckedContinuation<Void, Error>] = []
    private var terminalFailure: ShimFailure?
    private var isCancelling = false

    init(http: HTTPClientTransport, maximumConcurrentPosts: Int) {
        self.http = http
        self.maximumConcurrentPosts = max(1, maximumConcurrentPosts)
        var continuation: AsyncStream<ShimFailure>.Continuation!
        self.failures = AsyncStream { continuation = $0 }
        self.failureContinuation = continuation
    }

    func submit(_ frame: Data) async throws {
        if let terminalFailure { throw terminalFailure }
        if tasks.count >= maximumConcurrentPosts {
            try await withCheckedThrowingContinuation { continuation in
                slotWaiters.append(continuation)
            }
        }
        if let terminalFailure { throw terminalFailure }
        try Task.checkCancellation()

        let id = UUID()
        let http = http
        tasks[id] = Task {
            do {
                try await http.send(frame)
                self.complete(id: id, failure: nil)
            } catch {
                let failure = ShimFailure.httpFailure(for: error)
                self.complete(id: id, failure: failure)
            }
        }
    }

    func drainState() -> DrainState {
        if let terminalFailure {
            return .failed(terminalFailure)
        }
        return tasks.isEmpty ? .drained : .pending
    }

    func cancelAll() {
        isCancelling = true
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        for waiter in slotWaiters {
            waiter.resume(throwing: CancellationError())
        }
        slotWaiters.removeAll()
        failureContinuation.finish()
    }

    private func complete(id: UUID, failure: ShimFailure?) {
        tasks[id] = nil
        guard !isCancelling else { return }

        if let failure, terminalFailure == nil {
            terminalFailure = failure
            failureContinuation.yield(failure)
            for waiter in slotWaiters {
                waiter.resume(throwing: failure)
            }
            slotWaiters.removeAll()
            return
        }

        if !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume()
        }
    }
}

private final class SessionTerminator: @unchecked Sendable {
    private let endpoint: URL
    private let token: String
    private let configuration: URLSessionConfiguration

    init(endpoint: URL, token: String, configuration: URLSessionConfiguration) {
        self.endpoint = endpoint
        self.token = token
        self.configuration = configuration
    }

    func terminate(sessionID: String) async {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 1
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        _ = try? await session.data(for: request)
    }
}
