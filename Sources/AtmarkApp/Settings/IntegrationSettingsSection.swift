import AtmarkCore
import SwiftUI

struct IntegrationSettingsSection: View {
    let model: AtmarkPresentationModel
    let integration: SettingsIntegration

    private var moduleConfig: Config.ModuleConfig {
        model.config.modules[integration.id] ?? .init()
    }

    var body: some View {
        Section {
            Toggle("Enabled", isOn: enabledBinding)
                .disabled(model.isApplyingConfig)
            Toggle("Allow Changes", isOn: allowChangesBinding)
                .disabled(!moduleConfig.enabled || model.isApplyingConfig)
        } header: {
            Label(integration.name, systemImage: integration.systemImage)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { moduleConfig.enabled },
            set: { enabled in
                Task { await model.setModuleEnabled(enabled, module: integration.id) }
            }
        )
    }

    private var allowChangesBinding: Binding<Bool> {
        Binding(
            get: { moduleConfig.writes },
            set: { allowChanges in
                Task { await model.setModuleWrites(allowChanges, module: integration.id) }
            }
        )
    }
}
