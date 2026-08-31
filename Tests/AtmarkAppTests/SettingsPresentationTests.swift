import Testing

@testable import AtmarkApp

@Suite("Settings presentation")
struct SettingsPresentationTests {
    @Test("integration metadata is presentation-owned and sorted for display")
    func integrationMetadata() {
        let integrations = SettingsIntegration.sorted(
            moduleIDs: ["reminders", "calendar_events", "mail"]
        )

        #expect(integrations.map(\.id) == ["calendar_events", "mail", "reminders"])
        #expect(integrations.map(\.name) == ["Calendar Events", "Mail", "Reminders"])
        #expect(integrations.map(\.systemImage) == ["app", "envelope", "checklist"])
    }
}
