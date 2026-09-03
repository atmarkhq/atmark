import Darwin
import Foundation
import MCP

enum ShimTestError: Error {
    case pipeCreation
    case pipeIO
    case timedOut
    case missingHandler
}

final class PipeHarness: @unchecked Sendable {
    let shimTransport: StdioTransport

    private(set) var inputWriter: Int32
    private(set) var outputReader: Int32
    private let inputReader: Int32
    private let outputWriter: Int32
    private let lock = NSLock()
    private var openDescriptors: Set<Int32>

    init() throws {
        var input = [Int32](repeating: 0, count: 2)
        var output = [Int32](repeating: 0, count: 2)
        guard pipe(&input) == 0, pipe(&output) == 0 else {
            throw ShimTestError.pipeCreation
        }

        inputReader = input[0]
        inputWriter = input[1]
        outputReader = output[0]
        outputWriter = output[1]
        openDescriptors = Set(input + output)
        shimTransport = StdioTransport(
            input: .init(rawValue: inputReader),
            output: .init(rawValue: outputWriter),
            logger: nil
        )
    }

    deinit {
        lock.lock()
        let descriptors = openDescriptors
        openDescriptors.removeAll()
        lock.unlock()
        for descriptor in descriptors {
            Darwin.close(descriptor)
        }
    }

    func clientTransport() -> StdioTransport {
        StdioTransport(
            input: .init(rawValue: outputReader),
            output: .init(rawValue: inputWriter),
            logger: nil
        )
    }

    func write(frames: [Data]) throws {
        for frame in frames {
            var framed = frame
            framed.append(UInt8(ascii: "\n"))
            try writeAll(framed, to: inputWriter)
        }
    }

    func closeInput() {
        closeDescriptor(inputWriter)
    }

    func readFrames(count: Int, timeoutMilliseconds: Int = 2_000) async throws -> [Data] {
        let descriptor = outputReader
        return try await Task.detached {
            try readNewlineFrames(
                from: descriptor,
                count: count,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }.value
    }

    func finishOutputAndReadRemaining() throws -> Data {
        closeDescriptor(outputWriter)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(outputReader, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw ShimTestError.pipeIO
            }
            result.append(contentsOf: buffer[..<count])
        }
    }

    private func closeDescriptor(_ descriptor: Int32) {
        lock.lock()
        let wasOpen = openDescriptors.remove(descriptor) != nil
        lock.unlock()
        if wasOpen {
            Darwin.close(descriptor)
        }
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(
                descriptor,
                raw.baseAddress!.advanced(by: offset),
                raw.count - offset
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw ShimTestError.pipeIO
            }
            offset += count
        }
    }
}

private func readNewlineFrames(
    from descriptor: Int32,
    count expectedCount: Int,
    timeoutMilliseconds: Int
) throws -> [Data] {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    var pending = Data()
    var frames: [Data] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)

    while frames.count < expectedCount {
        let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1_000))
        guard remaining > 0 else { throw ShimTestError.timedOut }

        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptorState, 1, remaining)
        guard ready > 0 else {
            if ready < 0, errno == EINTR { continue }
            throw ready == 0 ? ShimTestError.timedOut : ShimTestError.pipeIO
        }

        let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
        guard bytesRead > 0 else {
            if bytesRead < 0, errno == EINTR { continue }
            throw ShimTestError.pipeIO
        }
        pending.append(contentsOf: buffer[..<bytesRead])

        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            frames.append(Data(pending[..<newline]))
            pending.removeSubrange(...newline)
            if frames.count == expectedCount { break }
        }
    }
    return frames
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct MockHTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var pauseBeforeFinish: AsyncGate?
}

actor MockRequestHandlerStorage {
    typealias Handler = @Sendable (URLRequest) async throws -> MockHTTPResponse
    private var handler: Handler?

    func set(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func clear() {
        handler = nil
    }

    func response(for request: URLRequest) async throws -> MockHTTPResponse {
        guard let handler else { throw ShimTestError.missingHandler }
        return try await handler(request)
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let storage = MockRequestHandlerStorage()
    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        loadingTask = Task {
            do {
                let plan = try await Self.storage.response(for: request)
                guard !Task.isCancelled, let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: plan.statusCode,
                          httpVersion: "HTTP/1.1",
                          headerFields: plan.headers
                      )
                else { return }

                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in plan.chunks {
                    guard !Task.isCancelled else { return }
                    client?.urlProtocol(self, didLoad: chunk)
                    await Task.yield()
                }
                if let gate = plan.pauseBeforeFinish {
                    await gate.wait()
                }
                guard !Task.isCancelled else { return }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

extension URLSessionConfiguration {
    static var shimMock: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }
}

extension URLRequest {
    /// URLSession may replace `httpBody` with a stream before a custom
    /// URLProtocol sees the request. Tests must inspect either representation or
    /// they will mistake a preserved payload for an empty one.
    func shimTestBody() -> Data {
        if let httpBody { return httpBody }
        guard let httpBodyStream else { return Data() }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while httpBodyStream.hasBytesAvailable {
            let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer[..<count])
        }
        return result
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func get() -> Bool {
        lock.withLock { value }
    }

    func set(_ value: Bool) {
        lock.withLock { self.value = value }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    func get() -> Int {
        lock.withLock { value }
    }
}

func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
