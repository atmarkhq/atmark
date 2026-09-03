import SwiftUI

struct AdvancedSettingsPane: View {
    let model: AtmarkPresentationModel

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Address", value: model.port == 0 ? "—" : model.host)
                LabeledContent("Port", value: model.port == 0 ? "—" : model.port.formatted())
                LabeledContent("Active Sessions", value: model.sessionCount.formatted())
            }

            Section("Diagnostics") {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .controlSize(.small)
            }

            SettingsErrorSection(message: model.errorMessage)
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    private func refresh() {
        Task { await model.refresh() }
    }
}
