import Foundation

struct SettingsIntegration: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let systemImage: String

    init(moduleID: String) {
        id = moduleID

        switch moduleID {
        case "mail":
            name = "Mail"
            systemImage = "envelope"
        case "reminders":
            name = "Reminders"
            systemImage = "checklist"
        default:
            name = moduleID
                .split(separator: "_")
                .map(\.capitalized)
                .joined(separator: " ")
            systemImage = "app"
        }
    }

    static func sorted<S: Sequence>(moduleIDs: S) -> [Self] where S.Element == String {
        moduleIDs
            .map(Self.init(moduleID:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
