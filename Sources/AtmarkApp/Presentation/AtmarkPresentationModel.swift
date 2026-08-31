import Observation
import AtmarkCore
import AtmarkServer

/// One presentation mirror shared by the menu-bar and Settings window.
/// The resident actors remain authoritative for server and permission state.
@MainActor
@Observable
final class AtmarkPresentationModel {
    private let runtime: any ServerRuntimeServing

    private(set) var state: AppRuntimeState = .starting
    private(set) var host = "127.0.0.1"
    private(set) var port = 0
    private(set) var sessionCount = 0
    private(set) var config = Config()
    private(set) var permissions = PermissionSnapshot(
        reminders: .unknown,
        mailAutomation: .unavailable,
        fullDiskAccess: .unknown
    )
    private(set) var isApplyingConfig = false
    private(set) var permissionActionInProgress: PermissionAction?
    private(set) var errorMessage: String?

    init(runtime: any ServerRuntimeServing) {
        self.runtime = runtime
    }

    var menuBarPresentation: MenuBarPresentation {
        let attentionItems = state == .running ? menuBarAttentionItems : []
        let semanticState: MenuBarPresentation.State

        switch state {
        case .starting:
            semanticState = .starting
        case .running:
            if usableEnabledIntegrationCount == 0 {
                semanticState = .setupRequired
            } else if attentionItems.isEmpty {
                semanticState = .ready
            } else {
                semanticState = .needsAttention
            }
        case .stopped:
            semanticState = .setupRequired
        case .failed:
            semanticState = .failed
        }

        return MenuBarPresentation(
            state: semanticState,
            statusText: menuBarStatusText(for: semanticState),
            detail: menuBarDetail(for: semanticState),
            attentionItems: attentionItems
        )
    }

    func start() async {
        do {
            apply(try await runtime.start())
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            apply(await runtime.snapshot())
            errorMessage = Self.userFacingDescription(for: error)
        }
    }

    func refresh() async {
        apply(await runtime.snapshot())
    }

    func permissionAction(
        for permission: PresentedPermission
    ) -> PermissionActionPresentation? {
        switch permission {
        case .reminders:
            switch permissions.reminders {
            case .notDetermined:
                PermissionActionPresentation(
                    action: .requestRemindersAccess,
                    title: "Request Access…"
                )
            case .denied, .restricted, .writeOnly:
                PermissionActionPresentation(
                    action: .openRemindersSettings,
                    title: "Open Reminders…"
                )
            case .granted, .unavailable, .unknown:
                nil
            }
        case .mailAutomation:
            switch permissions.mailAutomation {
            case .unavailable:
                PermissionActionPresentation(action: .openMail, title: "Open Mail…")
            case .notDetermined:
                PermissionActionPresentation(
                    action: .requestMailAutomationAccess,
                    title: "Request Access…"
                )
            case .denied, .restricted:
                PermissionActionPresentation(
                    action: .openAutomationSettings,
                    title: "Open Automation…"
                )
            case .writeOnly, .granted, .unknown:
                nil
            }
        case .mailData:
            PermissionActionPresentation(
                action: .openFullDiskAccessSettings,
                title: "Open Full Disk Access…"
            )
        }
    }

    func performPermissionAction(_ action: PermissionAction) async {
        guard permissionActionInProgress == nil else { return }
        permissionActionInProgress = action
        defer { permissionActionInProgress = nil }

        do {
            apply(try await runtime.performPermissionAction(action))
            errorMessage = nil
        } catch is CancellationError {
            apply(await runtime.snapshot())
        } catch {
            // Always refresh through the read-only path. A request result is not
            // itself proof of the current permission state.
            apply(await runtime.snapshot())
            errorMessage = Self.userFacingDescription(for: error)
        }
    }

    func setModuleEnabled(_ enabled: Bool, module: String) async {
        var candidate = config
        guard candidate.modules[module] != nil else { return }
        candidate.modules[module]?.enabled = enabled
        await applyConfig(candidate)
    }

    func setModuleWrites(_ writes: Bool, module: String) async {
        var candidate = config
        guard candidate.modules[module] != nil else { return }
        candidate.modules[module]?.writes = writes
        await applyConfig(candidate)
    }

    private func applyConfig(_ candidate: Config) async {
        guard candidate != config, !isApplyingConfig else { return }
        isApplyingConfig = true
        defer { isApplyingConfig = false }

        do {
            // Do not mutate `config` before both persistence and host update
            // succeed inside the runtime.
            apply(try await runtime.updateConfig(candidate))
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.userFacingDescription(for: error)
        }
    }

    private func apply(_ snapshot: AppRuntimeSnapshot) {
        state = snapshot.state
        if let server = snapshot.server {
            host = server.host
            port = server.port
            sessionCount = server.sessionCount
            config = server.config
            permissions = server.permissions
        }
        if snapshot.state == .failed, let detail = snapshot.detail {
            errorMessage = detail
        }
    }

    private var menuBarAttentionItems: [MenuBarPresentation.AttentionItem] {
        var items: [MenuBarPresentation.AttentionItem] = []

        if config.modules["reminders"]?.enabled == true,
           permissions.reminders != .granted,
           let action = permissionAction(for: .reminders) {
            items.append(
                MenuBarPresentation.AttentionItem(
                    id: .reminders,
                    title: "Reminders",
                    detail: remindersAttentionDetail,
                    symbolName: "checklist",
                    action: action
                )
            )
        }

        if config.modules["mail"]?.enabled == true {
            if permissions.mailAutomation != .granted,
               let action = permissionAction(for: .mailAutomation) {
                items.append(
                    MenuBarPresentation.AttentionItem(
                        id: .mailAutomation,
                        title: "Mail Automation",
                        detail: mailAutomationAttentionDetail,
                        symbolName: "mail",
                        action: action
                    )
                )
            }

            if permissions.fullDiskAccess != .granted,
               let action = permissionAction(for: .mailData) {
                items.append(
                    MenuBarPresentation.AttentionItem(
                        id: .mailData,
                        title: "Mail Data",
                        detail: "Add Atmark to Full Disk Access in System Settings.",
                        symbolName: "internaldrive",
                        action: action
                    )
                )
            }
        }

        return items
    }

    private var usableEnabledIntegrationCount: Int {
        var count = 0

        if let reminders = config.modules["reminders"], reminders.enabled,
           permissions.reminders == .granted
            || (permissions.reminders == .writeOnly && reminders.writes) {
            count += 1
        }

        if config.modules["mail"]?.enabled == true,
           permissions.mailAutomation == .granted || permissions.fullDiskAccess == .granted {
            count += 1
        }

        return count
    }

    private var remindersAttentionDetail: String {
        switch permissions.reminders {
        case .notDetermined:
            "Allow access before Atmark can use Reminders."
        case .denied, .restricted, .writeOnly:
            "Allow full Reminders access in System Settings."
        case .granted, .unavailable, .unknown:
            "Reminders access needs attention."
        }
    }

    private var mailAutomationAttentionDetail: String {
        switch permissions.mailAutomation {
        case .unavailable:
            "Open Mail to check Automation access."
        case .notDetermined:
            "Allow Atmark to control Mail."
        case .denied, .restricted:
            "Allow Atmark under Automation in System Settings."
        case .writeOnly, .granted, .unknown:
            "Mail Automation needs attention."
        }
    }

    private func menuBarStatusText(for state: MenuBarPresentation.State) -> String {
        switch state {
        case .starting: "Starting"
        case .ready: "Ready"
        case .needsAttention: "Needs attention"
        case .setupRequired: self.state == .stopped ? "Stopped" : "Setup required"
        case .failed: "Failed"
        }
    }

    private func menuBarDetail(for state: MenuBarPresentation.State) -> String? {
        if let errorMessage { return errorMessage }

        return switch state {
        case .setupRequired where self.state == .running:
            "Enable an integration and finish its access setup."
        case .setupRequired:
            "Atmark is not accepting MCP connections."
        case .failed:
            "Atmark could not start."
        case .starting, .ready, .needsAttention:
            nil
        }
    }

    private static func userFacingDescription(for error: any Error) -> String {
        if let error = error as? AtmarkError {
            return error.hint
        }
        return error.localizedDescription
    }
}
