enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case integrations
    case privacy
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .integrations: "Apps"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .integrations: "square.grid.2x2"
        case .privacy: "hand.raised"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}
