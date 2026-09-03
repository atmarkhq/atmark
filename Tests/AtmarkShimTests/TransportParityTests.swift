import Foundation
import MCP
import AtmarkCore
import AtmarkServer
import Testing

@testable import AtmarkShim

@Suite("Shim and direct HTTP parity", .serialized)
struct TransportParityTests {
    private struct TestPermissionProvider: PermissionProviding {
        func currentPermissions() async -> PermissionSnapshot {
            PermissionSnapshot(
                reminders: .notDetermined,
                mailAutomation: .unavailable,
                fullDiskAccess: .unavailable
            )
        }
    }

    @Test("direct HTTP and shim expose the same tools/list surface", .timeLimit(.minutes(1)))
    func directAndShimToolsListParity() async throws {
        let credential = "test-only-parity-bearer"
        let host = ServerHost(
            config: Config(),
            tokenStore: .local(token: credential),
            registry: ProductionToolCatalogue.registry,
            permissionProvider: TestPermissionProvider()
        )
        let listener = HTTPListener(host: "127.0.0.1", port: 0, serverHost: host)
        let port = try await listener.start()
        let endpointURL = URL(string: "http://127.0.0.1:\(port)/mcp")!

        do {
            let directTransport = authenticatedHTTPTransport(
                endpoint: endpointURL,
                credential: credential
            )
            let directClient = Client(name: "direct-test", version: "1")
            try await directClient.connect(transport: directTransport)
            let direct = try await directClient.listTools()
            await directClient.disconnect()

            let harness = try PipeHarness()
            let relay = ShimRelay(
                endpoint: ShimEndpoint(
                    port: port,
                    host: "127.0.0.1",
                    token: credential,
                    pid: ProcessInfo.processInfo.processIdentifier
                ),
                stdio: harness.shimTransport,
                processIsAlive: { _ in true }
            )
            let relayTask = Task { try await relay.run() }
            let shimClient = Client(name: "shim-test", version: "1")
            try await shimClient.connect(transport: harness.clientTransport())
            let throughShim = try await shimClient.listTools()
            await shimClient.disconnect()
            harness.closeInput()
            try await relayTask.value

            #expect(throughShim.tools == direct.tools)
            #expect(throughShim.nextCursor == direct.nextCursor)
        } catch {
            await host.shutdown()
            await listener.stop()
            throw error
        }

        await host.shutdown()
        await listener.stop()
    }

    private func authenticatedHTTPTransport(
        endpoint: URL,
        credential: String
    ) -> HTTPClientTransport {
        HTTPClientTransport(
            endpoint: endpoint,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                return request
            },
            logger: nil
        )
    }
}
