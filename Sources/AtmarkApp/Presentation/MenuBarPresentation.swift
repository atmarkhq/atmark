struct MenuBarPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case starting
        case ready
        case needsAttention
        case setupRequired
        case failed

        var symbolName: String {
            switch self {
            case .starting: "clock"
            case .ready: "apple.logo"
            case .needsAttention: "exclamationmark.triangle"
            case .setupRequired: "bolt.slash"
            case .failed: "xmark.octagon"
            }
        }
    }

    struct AttentionItem: Equatable, Identifiable, Sendable {
        enum ID: Equatable, Hashable, Sendable {
            case reminders
            case mailAutomation
            case mailData
        }

        let id: ID
        let title: String
        let detail: String
        let symbolName: String
        let action: PermissionActionPresentation
    }

    let state: State
    let statusText: String
    let detail: String?
    let attentionItems: [AttentionItem]

    var symbolName: String { state.symbolName }

    var accessibilityLabel: String {
        "Atmark, \(statusText)"
    }
}
