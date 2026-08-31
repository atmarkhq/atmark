import SwiftUI

struct IntegrationsSettingsPane: View {
    let model: AtmarkPresentationModel

    private var integrations: [SettingsIntegration] {
        SettingsIntegration.sorted(moduleIDs: model.config.modules.keys)
    }

    var body: some View {
        Form {
            ForEach(integrations) { integration in
                IntegrationSettingsSection(model: model, integration: integration)
            }

            SettingsErrorSection(message: model.errorMessage)
        }
        .formStyle(.grouped)
        .navigationTitle("Apps & Integrations")
    }
}
