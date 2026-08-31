import AtmarkCore

/// Live actor-owned values consumed by the app's presentation mirror.
public struct ServerSnapshot: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let sessionCount: Int
    public let config: Config
    public let permissions: PermissionSnapshot

    public init(
        host: String,
        port: Int,
        sessionCount: Int,
        config: Config,
        permissions: PermissionSnapshot
    ) {
        self.host = host
        self.port = port
        self.sessionCount = sessionCount
        self.config = config
        self.permissions = permissions
    }
}
