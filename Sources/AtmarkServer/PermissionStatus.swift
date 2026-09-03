import AtmarkCore

/// Compact permission states shared by the GUI and `atmark_status`.
public enum PermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case restricted
    case writeOnly = "write_only"
    case granted
    case unavailable
    case unknown
}

/// Atmark's deliberately narrow permission snapshot.
///
/// `fullDiskAccess` keeps the established wire key, but represents only effective
/// read access to Mail's existing data directory. macOS exposes no supported API
/// that lets an ordinary app claim global Full Disk Access certainty.
public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let reminders: PermissionState
    public let mailAutomation: PermissionState
    public let fullDiskAccess: PermissionState

    public init(
        reminders: PermissionState,
        mailAutomation: PermissionState,
        fullDiskAccess: PermissionState
    ) {
        self.reminders = reminders
        self.mailAutomation = mailAutomation
        self.fullDiskAccess = fullDiskAccess
    }

    private enum CodingKeys: String, CodingKey {
        case reminders
        case mailAutomation = "mail_automation"
        case fullDiskAccess = "full_disk_access"
    }

    public var json: JSONValue {
        .object([
            "reminders": .string(reminders.rawValue),
            "mail_automation": .string(mailAutomation.rawValue),
            "full_disk_access": .string(fullDiskAccess.rawValue),
        ])
    }
}

/// Injected into `ServerHost` so tests never inspect live TCC state.
public protocol PermissionProviding: Sendable {
    func currentPermissions() async -> PermissionSnapshot
}
