import SwiftUI

@main
struct AtmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            AtmarkMenuView(model: delegate.model)
        } label: {
            Label(
                delegate.model.menuBarPresentation.accessibilityLabel,
                systemImage: delegate.model.menuBarPresentation.symbolName
            )
            .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                AtmarkSettingsButton()
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Atmark Settings", id: AtmarkWindow.settingsID) {
            AtmarkSettingsView(model: delegate.model)
        }
        .defaultSize(width: 720, height: 500)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
    }
}
