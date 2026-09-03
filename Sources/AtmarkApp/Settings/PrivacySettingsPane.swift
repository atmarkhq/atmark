import SwiftUI

struct PrivacySettingsPane: View {
    let model: AtmarkPresentationModel

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionSettingsRow(
                    title: "Reminders",
                    systemImage: "checklist",
                    detail: "Current Reminders authorization reported by macOS.",
                    state: model.permissions.reminders,
                    permission: .reminders,
                    model: model
                )
                PermissionSettingsRow(
                    title: "Mail Automation",
                    systemImage: "envelope",
                    detail: "Target-specific Apple Events access for Mail, checked only while Mail is running.",
                    state: model.permissions.mailAutomation,
                    permission: .mailAutomation,
                    model: model
                )
                PermissionSettingsRow(
                    title: "Mail Data",
                    systemImage: "internaldrive",
                    detail: "Whether Atmark can currently read ~/Library/Mail. macOS does not expose a global Full Disk Access status or a request API.",
                    state: model.permissions.fullDiskAccess,
                    permission: .mailData,
                    model: model
                )
            }

            SettingsErrorSection(message: model.errorMessage)
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }
}
