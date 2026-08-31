import AtmarkServer

enum PresentedPermission: Sendable {
    case reminders
    case mailAutomation
    case mailData
}

struct PermissionActionPresentation: Equatable, Sendable {
    let action: PermissionAction
    let title: String
}

extension AppRuntimeState {
    var displayName: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Not running"
        }
    }
}

extension PermissionState {
    var displayName: String {
        switch self {
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Write only"
        case .granted: "Granted"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}
