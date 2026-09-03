import Darwin
import Foundation

struct ShimEndpoint: Codable, Sendable {
    let port: Int
    let host: String
    let token: String
    let pid: Int32

    var url: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/mcp"
        return components.url
    }

    var isValid: Bool {
        (1...65_535).contains(port)
            && !token.isEmpty
            && pid > 0
            && Self.isLoopback(host)
            && url != nil
    }

    private static func isLoopback(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { raw in
                raw.enumerated().allSatisfy { index, byte in
                    byte == (index == raw.count - 1 ? 1 : 0)
                }
            }
        }
        return false
    }
}

enum ReadinessProbeResult: Sendable {
    case ready
    case authenticationFailed
    case connectionFailed
    case notReady
}

struct EndpointResolver: Sendable {
    typealias Launcher = @Sendable () async throws -> Void
    typealias ProcessLiveness = @Sendable (Int32) -> Bool
    typealias Probe = @Sendable (ShimEndpoint, TimeInterval) async -> ReadinessProbeResult

    let endpointURL: URL
    let readinessTimeout: Duration
    let pollInterval: Duration
    let requestTimeout: TimeInterval
    let launchApp: Launcher
    let processIsAlive: ProcessLiveness
    let probe: Probe

    init(
        endpointURL: URL = Self.defaultEndpointURL,
        readinessTimeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(100),
        requestTimeout: TimeInterval = 1,
        launchApp: @escaping Launcher = FixedAppLauncher.launch,
        processIsAlive: @escaping ProcessLiveness = Self.defaultProcessIsAlive,
        probe: @escaping Probe = ReadinessProbe.perform
    ) {
        self.endpointURL = endpointURL
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.launchApp = launchApp
        self.processIsAlive = processIsAlive
        self.probe = probe
    }

    func resolve() async throws -> ShimEndpoint {
        let clock = ContinuousClock()
        var state = await inspect(probeTimeout: requestTimeout)
        if case .ready(let endpoint) = state {
            return endpoint
        }

        do {
            try await launchApp()
        } catch {
            throw ShimFailure.launchFailed
        }

        let deadline = clock.now.advanced(by: readinessTimeout)
        repeat {
            let remaining = clock.now.duration(to: deadline)
            let timeout = max(0.01, min(requestTimeout, remaining.timeInterval))
            state = await inspect(probeTimeout: timeout)
            if case .ready(let endpoint) = state {
                return endpoint
            }

            let afterProbe = clock.now.duration(to: deadline)
            guard afterProbe > .zero else { break }
            try? await Task.sleep(for: min(pollInterval, afterProbe))
        } while clock.now < deadline

        throw state.failure
    }

    private func inspect(probeTimeout: TimeInterval) async -> EndpointState {
        guard FileManager.default.fileExists(atPath: endpointURL.path(percentEncoded: false)) else {
            return .missing
        }

        let data: Data
        let permissions: Int
        do {
            data = try Data(contentsOf: endpointURL)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: endpointURL.path(percentEncoded: false)
            )
            guard let mode = attributes[.posixPermissions] as? NSNumber else {
                return .malformed
            }
            permissions = mode.intValue & 0o777
        } catch {
            return .malformed
        }

        guard permissions == 0o600,
              let endpoint = try? JSONDecoder().decode(ShimEndpoint.self, from: data),
              endpoint.isValid
        else {
            return .malformed
        }
        guard processIsAlive(endpoint.pid) else {
            return .stale
        }

        switch await probe(endpoint, probeTimeout) {
        case .ready:
            return .ready(endpoint)
        case .authenticationFailed:
            return .authenticationFailed
        case .connectionFailed:
            return .connectionFailed
        case .notReady:
            return .notReady
        }
    }

    static var defaultEndpointURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Atmark", directoryHint: .isDirectory)
            .appending(path: "endpoint.json")
    }

    static func defaultProcessIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

private enum EndpointState: Sendable {
    case ready(ShimEndpoint)
    case missing
    case malformed
    case stale
    case authenticationFailed
    case connectionFailed
    case notReady

    var failure: ShimFailure {
        switch self {
        case .ready:
            preconditionFailure("A ready endpoint is not a failure")
        case .missing:
            return .endpointMissing
        case .malformed:
            return .endpointMalformed
        case .stale:
            return .endpointStale
        case .authenticationFailed:
            return .authenticationFailed
        case .connectionFailed:
            return .connectionFailed
        case .notReady:
            return .readinessTimedOut
        }
    }
}

private enum ReadinessProbe {
    static func perform(
        endpoint: ShimEndpoint,
        timeout: TimeInterval
    ) async -> ReadinessProbeResult {
        guard let url = endpoint.url else { return .notReady }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .connectionFailed
            }
            switch http.statusCode {
            case 400:
                // The resident server authenticates first, then rejects this
                // deliberate sessionless GET as its readiness response.
                return .ready
            case 401, 403:
                return .authenticationFailed
            default:
                return .notReady
            }
        } catch {
            return .connectionFailed
        }
    }
}

private enum FixedAppLauncher {
    static func launch() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "io.github.atmarkhq.atmark"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        if !(await waitForExit(process, timeout: .seconds(3))) {
            process.terminate()
            if !(await waitForExit(process, timeout: .milliseconds(250))) {
                kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(process, timeout: .milliseconds(250))
            }
        }

        guard !process.isRunning, process.terminationStatus == 0 else {
            throw ShimFailure.launchFailed
        }
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: min(.milliseconds(10), clock.now.duration(to: deadline)))
        }
        return !process.isRunning
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
