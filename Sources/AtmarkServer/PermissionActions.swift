import AppKit
import Carbon
import EventKit
import Foundation

/// Actions that may prompt for permission or open another application.
///
/// These are deliberately separate from `PermissionProviding`: server status,
/// `atmark_status`, and passive GUI refreshes receive only the read-only
/// protocol and therefore cannot trigger one of these operations.
public enum PermissionAction: Equatable, Sendable {
    case requestRemindersAccess
    case openRemindersSettings
    case openMail
    case requestMailAutomationAccess
    case openAutomationSettings
    case openFullDiskAccessSettings
}

public protocol PermissionActionPerforming: Sendable {
    func perform(_ action: PermissionAction) async throws
}

public enum PermissionActionError: Error, Equatable, Sendable {
    case remindersAccessNotGranted
    case remindersRequestFailed
    case mailUnavailable
    case mailLaunchFailed
    case mailAutomationAccessNotGranted
    case mailAutomationConsentNotCompleted
    case mailNotRunning
    case mailAutomationRequestFailed(OSStatus)
    case privacySettingsUnavailable
}

extension PermissionActionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .remindersAccessNotGranted:
            "Reminders access was not granted. Open Privacy & Security > Reminders to allow Atmark."
        case .remindersRequestFailed:
            "Atmark could not request Reminders access. Open Privacy & Security > Reminders and try again."
        case .mailUnavailable:
            "Mail could not be found. Install or restore Apple Mail, then try again."
        case .mailLaunchFailed:
            "Atmark could not open Mail. Open Apple Mail manually, then refresh and try again."
        case .mailAutomationAccessNotGranted:
            "Mail Automation access was not granted. Open Privacy & Security > Automation to allow Atmark."
        case .mailAutomationConsentNotCompleted:
            "The Mail Automation request did not complete. Keep Mail open, then try Request Access again."
        case .mailNotRunning:
            "Mail closed before permission could be requested. Open Mail, refresh, then try again."
        case .mailAutomationRequestFailed(let status):
            "The Mail Automation request failed (OSStatus \(status)). Keep Mail open and try again."
        case .privacySettingsUnavailable:
            "System Settings could not be opened. Open Privacy & Security manually and try again."
        }
    }
}

extension SystemPermissionProvider: PermissionActionPerforming {
    public func perform(_ action: PermissionAction) async throws {
        switch action {
        case .requestRemindersAccess:
            try await Self.requestRemindersAccess()
        case .openRemindersSettings:
            try await Self.openPrivacySettings(route: "Privacy_Reminders")
        case .openMail:
            try await Self.openMail()
        case .requestMailAutomationAccess:
            try await Self.requestMailAutomationAccess()
        case .openAutomationSettings:
            try await Self.openPrivacySettings(route: "Privacy_Automation")
        case .openFullDiskAccessSettings:
            try await Self.openPrivacySettings(route: "Privacy_AllFiles")
        }
    }

    static func remindersRequestError(granted: Bool) -> PermissionActionError? {
        granted ? nil : .remindersAccessNotGranted
    }

    static func mailAutomationRequestError(for status: OSStatus) -> PermissionActionError? {
        switch status {
        case noErr:
            nil
        case OSStatus(errAEEventNotPermitted):
            .mailAutomationAccessNotGranted
        case OSStatus(errAEEventWouldRequireUserConsent):
            .mailAutomationConsentNotCompleted
        case OSStatus(procNotFound):
            .mailNotRunning
        default:
            .mailAutomationRequestFailed(status)
        }
    }

    @MainActor
    private static func requestRemindersAccess() async throws {
        do {
            let granted = try await EKEventStore().requestFullAccessToReminders()
            if let error = remindersRequestError(granted: granted) {
                throw error
            }
        } catch let error as PermissionActionError {
            throw error
        } catch {
            throw PermissionActionError.remindersRequestFailed
        }
    }

    @MainActor
    private static func openMail() async throws {
        let workspace = NSWorkspace.shared
        guard let mailURL = workspace.urlForApplication(
            withBundleIdentifier: mailBundleIdentifier
        ) else {
            throw PermissionActionError.mailUnavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.openApplication(
                at: mailURL,
                configuration: configuration
            )
        } catch {
            throw PermissionActionError.mailLaunchFailed
        }
    }

    /// Apple documents that a prompting determination may block arbitrarily,
    /// so this action explicitly leaves the caller's actor.
    @concurrent
    private static func requestMailAutomationAccess() async throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: mailBundleIdentifier)
        guard let descriptor = target.aeDesc else {
            throw PermissionActionError.mailNotRunning
        }
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor,
            typeWildCard,
            typeWildCard,
            true
        )
        if let error = mailAutomationRequestError(for: status) {
            throw error
        }
    }

    @MainActor
    private static func openPrivacySettings(route: String) async throws {
        let base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        guard let routeURL = URL(string: "\(base)?\(route)"),
              let fallbackURL = URL(string: base)
        else {
            throw PermissionActionError.privacySettingsUnavailable
        }

        do {
            try await open(routeURL)
        } catch {
            do {
                try await open(fallbackURL)
            } catch {
                throw PermissionActionError.privacySettingsUnavailable
            }
        }
    }

    @MainActor
    private static func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }
}
