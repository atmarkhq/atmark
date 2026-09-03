import AtmarkCore
import AtmarkServer

#if DEBUG
/// Deterministic, in-memory runtime used only by SwiftUI previews.
/// It never starts services, reads permissions, or persists configuration.
actor PreviewRuntime: ServerRuntimeServing {
    enum Fixture: Sendable {
        case ready
        case needsAttention
        case setupRequired
        case failed

        var snapshot: AppRuntimeSnapshot {
            switch self {
            case .ready:
                runningSnapshot(
                    permissions: PermissionSnapshot(
                        reminders: .granted,
                        mailAutomation: .granted,
                        fullDiskAccess: .granted
                    )
                )
            case .needsAttention:
                runningSnapshot(
                    permissions: PermissionSnapshot(
                        reminders: .notDetermined,
                        mailAutomation: .granted,
                        fullDiskAccess: .denied
                    )
                )
            case .setupRequired:
                runningSnapshot(
                    config: Config(
                        modules: [
                            "reminders": .init(enabled: false),
                            "mail": .init(enabled: false),
                        ]
                    ),
                    permissions: PermissionSnapshot(
                        reminders: .granted,
                        mailAutomation: .granted,
                        fullDiskAccess: .granted
                    )
                )
            case .failed:
                AppRuntimeSnapshot(
                    state: .failed,
                    detail: "The local MCP listener could not start.",
                    server: nil
                )
            }
        }

        private func runningSnapshot(
            config: Config = Config(),
            permissions: PermissionSnapshot
        ) -> AppRuntimeSnapshot {
            AppRuntimeSnapshot(
                state: .running,
                detail: nil,
                server: ServerSnapshot(
                    host: "127.0.0.1",
                    port: 49_152,
                    sessionCount: 2,
                    config: config,
                    permissions: permissions
                )
            )
        }
    }

    private var value: AppRuntimeSnapshot

    init(_ fixture: Fixture) {
        value = fixture.snapshot
    }

    func start() async throws -> AppRuntimeSnapshot { value }

    func snapshot() async -> AppRuntimeSnapshot { value }

    func updateConfig(_ config: Config) async throws -> AppRuntimeSnapshot {
        try config.validate()
        guard let server = value.server else { return value }
        value = replacing(server, config: config, permissions: server.permissions)
        return value
    }

    func performPermissionAction(
        _ action: PermissionAction
    ) async throws -> AppRuntimeSnapshot {
        guard let server = value.server else { return value }
        let permissions = switch action {
        case .requestRemindersAccess:
            PermissionSnapshot(
                reminders: .granted,
                mailAutomation: server.permissions.mailAutomation,
                fullDiskAccess: server.permissions.fullDiskAccess
            )
        case .openMail:
            PermissionSnapshot(
                reminders: server.permissions.reminders,
                mailAutomation: .notDetermined,
                fullDiskAccess: server.permissions.fullDiskAccess
            )
        case .requestMailAutomationAccess:
            PermissionSnapshot(
                reminders: server.permissions.reminders,
                mailAutomation: .granted,
                fullDiskAccess: server.permissions.fullDiskAccess
            )
        case .openRemindersSettings, .openAutomationSettings, .openFullDiskAccessSettings:
            server.permissions
        }

        value = replacing(server, config: server.config, permissions: permissions)
        return value
    }

    func stop() async {
        value = AppRuntimeSnapshot(state: .stopped, detail: nil, server: nil)
    }

    private func replacing(
        _ server: ServerSnapshot,
        config: Config,
        permissions: PermissionSnapshot
    ) -> AppRuntimeSnapshot {
        AppRuntimeSnapshot(
            state: .running,
            detail: nil,
            server: ServerSnapshot(
                host: server.host,
                port: server.port,
                sessionCount: server.sessionCount,
                config: config,
                permissions: permissions
            )
        )
    }
}
#endif
