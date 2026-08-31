import AtmarkServer
import SwiftUI

struct PermissionSettingsRow: View {
    let title: String
    let systemImage: String
    let detail: String
    let state: PermissionState
    let permission: PresentedPermission
    let model: AtmarkPresentationModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(state.displayName)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                PermissionActionControl(
                    model: model,
                    presentation: model.permissionAction(for: permission)
                )
            }
        }
    }
}
