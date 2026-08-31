import SwiftUI

struct SettingsErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section("Action Needed") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
