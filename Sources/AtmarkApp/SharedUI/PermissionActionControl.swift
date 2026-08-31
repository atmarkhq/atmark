import SwiftUI

struct PermissionActionControl: View {
    let model: AtmarkPresentationModel
    let presentation: PermissionActionPresentation?

    var body: some View {
        if let presentation {
            if model.permissionActionInProgress == presentation.action {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Permission action in progress")
            }
            Button(presentation.title, action: perform)
                .disabled(model.permissionActionInProgress != nil)
        }
    }

    private func perform() {
        guard let presentation else { return }
        Task { await model.performPermissionAction(presentation.action) }
    }
}
