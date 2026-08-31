import AppKit
import SwiftUI

struct AtmarkSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…", action: open)
    }

    private func open() {
        NSApp.activate()
        openWindow(id: AtmarkWindow.settingsID)
    }
}
