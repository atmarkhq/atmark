import SwiftUI

struct GeneralSettingsPane: View {
    let model: AtmarkPresentationModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: model.state.displayName)
                Toggle("MCP Server", isOn: .constant(model.state == .running))
                    .disabled(true)
            } header: {
                Text("Service")
            } footer: {
                Text("The MCP Server control is read-only in this development build.")
            }

            SettingsErrorSection(message: model.errorMessage)
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
