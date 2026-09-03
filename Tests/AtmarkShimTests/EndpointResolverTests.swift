import Darwin
import Foundation
import Testing

@testable import AtmarkShim

@Suite("Shim endpoint discovery")
struct EndpointResolverTests {
    @Test("a missing endpoint launches the fixed app path and accepts the fresh endpoint")
    func missingEndpointLaunchesAndBecomesReady() async throws {
        let url = temporaryEndpointURL()
        let launches = LockedCounter()
        let endpoint = fixtureEndpoint()
        let resolver = EndpointResolver(
            endpointURL: url,
            readinessTimeout: .milliseconds(100),
            pollInterval: .milliseconds(1),
            launchApp: {
                launches.increment()
                try write(endpoint, to: url)
            },
            processIsAlive: { _ in true },
            probe: { _, _ in .ready }
        )

        let resolved = try await resolver.resolve()
        #expect(launches.get() == 1)
        #expect(resolved.port == endpoint.port)
        #expect(resolved.host == endpoint.host)
    }

    @Test("a missing endpoint after launch is reported distinctly")
    func missingEndpointFailure() async {
        let failure = await resolveFailure(endpointURL: temporaryEndpointURL())
        #expect(failure == .endpointMissing)
    }

    @Test("a malformed endpoint is rejected")
    func malformedEndpointFailure() async throws {
        let url = temporaryEndpointURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)
        chmod(url.path(percentEncoded: false), 0o600)

        let failure = await resolveFailure(endpointURL: url)
        #expect(failure == .endpointMalformed)
    }

    @Test("a valid endpoint with non-private permissions is rejected")
    func nonPrivateEndpointFailure() async throws {
        let url = temporaryEndpointURL()
        try write(fixtureEndpoint(), to: url)
        chmod(url.path(percentEncoded: false), 0o644)

        let failure = await resolveFailure(endpointURL: url)
        #expect(failure == .endpointMalformed)
    }

    @Test("an endpoint from a dead resident process is stale")
    func staleEndpointFailure() async throws {
        let url = temporaryEndpointURL()
        try write(fixtureEndpoint(), to: url)
        let failure = await resolveFailure(endpointURL: url, processIsAlive: { _ in false })
        #expect(failure == .endpointStale)
    }

    @Test("app launch failure is actionable and distinct")
    func launchFailure() async {
        let resolver = EndpointResolver(
            endpointURL: temporaryEndpointURL(),
            readinessTimeout: .milliseconds(5),
            launchApp: { throw ShimTestError.pipeIO },
            processIsAlive: { _ in true },
            probe: { _, _ in .ready }
        )
        let failure = await capturedFailure { try await resolver.resolve() }
        #expect(failure == .launchFailed)
    }

    @Test("not-ready, authentication, and connection failures remain distinct")
    func probeFailuresAreDistinct() async throws {
        let cases: [(ReadinessProbeResult, ShimFailure)] = [
            (.notReady, .readinessTimedOut),
            (.authenticationFailed, .authenticationFailed),
            (.connectionFailed, .connectionFailed),
        ]

        for (probeResult, expected) in cases {
            let url = temporaryEndpointURL()
            try write(fixtureEndpoint(), to: url)
            let resolver = EndpointResolver(
                endpointURL: url,
                readinessTimeout: .milliseconds(5),
                pollInterval: .milliseconds(1),
                launchApp: {},
                processIsAlive: { _ in true },
                probe: { _, _ in probeResult }
            )
            let failure = await capturedFailure { try await resolver.resolve() }
            #expect(failure == expected)
        }
    }

    @Test("diagnostics never contain the bearer credential")
    func diagnosticsRedactBearer() {
        let credential = fixtureEndpoint().token
        for failure in allFailures {
            let leaked = failure.diagnostic.contains(credential)
            #expect(leaked == false, "A shim diagnostic exposed endpoint credentials")
        }
    }

    private func resolveFailure(
        endpointURL: URL,
        processIsAlive: @escaping @Sendable (Int32) -> Bool = { _ in true }
    ) async -> ShimFailure? {
        let resolver = EndpointResolver(
            endpointURL: endpointURL,
            readinessTimeout: .milliseconds(5),
            pollInterval: .milliseconds(1),
            launchApp: {},
            processIsAlive: processIsAlive,
            probe: { _, _ in .ready }
        )
        return await capturedFailure { try await resolver.resolve() }
    }

    private func capturedFailure(
        _ operation: () async throws -> ShimEndpoint
    ) async -> ShimFailure? {
        do {
            _ = try await operation()
            return nil
        } catch let failure as ShimFailure {
            return failure
        } catch {
            return nil
        }
    }

    private func fixtureEndpoint() -> ShimEndpoint {
        ShimEndpoint(port: 51_234, host: "127.0.0.1", token: "test-only-bearer", pid: 42)
    }

    private func temporaryEndpointURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "endpoint.json")
    }

    private func write(_ endpoint: ShimEndpoint, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(endpoint).write(to: url)
        chmod(url.path(percentEncoded: false), 0o600)
    }

    private var allFailures: [ShimFailure] {
        [
            .endpointMissing, .endpointMalformed, .endpointStale, .launchFailed,
            .readinessTimedOut, .authenticationFailed, .connectionFailed,
            .residentStopped, .stdioConnectionFailed, .stdioOutputFailed,
        ]
    }
}
