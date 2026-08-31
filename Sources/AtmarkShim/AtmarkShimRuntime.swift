import Foundation
import MCP

public enum ShimFailure: Error, Equatable, Sendable {
    case endpointMissing
    case endpointMalformed
    case endpointStale
    case launchFailed
    case readinessTimedOut
    case authenticationFailed
    case connectionFailed
    case residentStopped
    case stdioConnectionFailed
    case stdioOutputFailed

    public var diagnostic: String {
        switch self {
        case .endpointMissing:
            return "atmark-shim: Atmark.app launched, but endpoint.json was not published. Open Atmark's menu-bar item and check its startup status."
        case .endpointMalformed:
            return "atmark-shim: endpoint.json is malformed or not private (mode 0600). Quit and relaunch Atmark.app to republish it."
        case .endpointStale:
            return "atmark-shim: endpoint.json still belongs to a stopped Atmark process. Quit and relaunch Atmark.app."
        case .launchFailed:
            return "atmark-shim: macOS could not launch Atmark.app. Install the signed app bundle, then open it once manually."
        case .readinessTimedOut:
            return "atmark-shim: Atmark.app did not become ready before the startup deadline. Open its menu-bar item and check the server status."
        case .authenticationFailed:
            return "atmark-shim: Atmark rejected the published endpoint credentials. Quit and relaunch Atmark.app to rotate the endpoint."
        case .connectionFailed:
            return "atmark-shim: the resident Atmark server connection failed. Confirm Atmark.app is running, then reconnect the MCP client."
        case .residentStopped:
            return "atmark-shim: the resident Atmark.app process stopped. Relaunch it, then reconnect the MCP client."
        case .stdioConnectionFailed:
            return "atmark-shim: could not open the MCP client's stdio channel. Restart the client and reconnect."
        case .stdioOutputFailed:
            return "atmark-shim: the MCP client's stdout channel closed while a response was being delivered. Reconnect the client."
        }
    }

    static func httpFailure(for error: Error) -> ShimFailure {
        guard case .internalError(let message) = error as? MCPError else {
            return .connectionFailed
        }
        switch message {
        case "Authentication required", "Access forbidden":
            return .authenticationFailed
        default:
            return .connectionFailed
        }
    }
}

public struct AtmarkShimRuntime {
    public init() {}

    public func run() async throws {
        let endpoint = try await EndpointResolver().resolve()
        let stdio = StdioTransport(logger: nil)
        let configuration = URLSessionConfiguration.ephemeral

        let relay = ShimRelay(
            endpoint: endpoint,
            stdio: stdio,
            urlSessionConfiguration: configuration
        )
        try await relay.run()
    }
}
