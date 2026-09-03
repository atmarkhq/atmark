import AppKit
import SwiftUI

struct AtmarkMenuView: View {
    let model: AtmarkPresentationModel

    var body: some View {
        let presentation = model.menuBarPresentation

        VStack(alignment: .leading, spacing: 0) {
            AtmarkMenuHeader(
                presentation: presentation,
                isServerRunning: model.state == .running
            )

            if presentation.attentionItems.isEmpty == false {
                Divider()
                AtmarkNeedsAttentionSection(
                    items: presentation.attentionItems,
                    model: model
                )
            }

            Divider()
            AtmarkMenuFooter()
        }
        .frame(width: 312)
        .task { await model.refresh() }
    }
}

private struct AtmarkMenuHeader: View {
    let presentation: MenuBarPresentation
    let isServerRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atmark")
                        .font(.headline)
                    Label(presentation.statusText, systemImage: presentation.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("MCP Server", isOn: .constant(isServerRunning))
                    .toggleStyle(.switch)
                    .disabled(true)
                    .fixedSize()
            }

            if let detail = presentation.detail {
                Label(detail, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
    }
}

private struct AtmarkNeedsAttentionSection: View {
    let items: [MenuBarPresentation.AttentionItem]
    let model: AtmarkPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs Attention")
                .font(.headline)

            ForEach(items) { item in
                AtmarkAttentionRow(item: item, model: model)
            }
        }
        .padding(14)
    }
}

private struct AtmarkAttentionRow: View {
    let item: MenuBarPresentation.AttentionItem
    let model: AtmarkPresentationModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbolName)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionActionControl(model: model, presentation: item.action)
                    .controlSize(.small)
            }
        }
    }
}

private struct AtmarkMenuFooter: View {
    var body: some View {
        HStack {
            AtmarkSettingsButton()
            Spacer()
            Button("Quit", action: quit)
                .keyboardShortcut("q")
        }
        .padding(10)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

#if DEBUG
private struct AtmarkMenuPreview: View {
    @State private var model: AtmarkPresentationModel

    init(_ fixture: PreviewRuntime.Fixture) {
        _model = State(
            initialValue: AtmarkPresentationModel(runtime: PreviewRuntime(fixture))
        )
    }

    var body: some View {
        AtmarkMenuView(model: model)
    }
}

#Preview("Ready") {
    AtmarkMenuPreview(.ready)
}

#Preview("Needs Attention") {
    AtmarkMenuPreview(.needsAttention)
}

#Preview("Setup Required") {
    AtmarkMenuPreview(.setupRequired)
}

#Preview("Failed") {
    AtmarkMenuPreview(.failed)
}
#endif
