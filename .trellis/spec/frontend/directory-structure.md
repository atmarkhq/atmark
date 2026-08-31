# App Directory Structure

`Sources/AtmarkApp` is organized by responsibility:

- `App/` owns the SwiftUI entry point and application/window integration.
  `App/AtmarkApp.swift` declares `MenuBarExtra`, the Settings window, and commands.
- `Runtime/` owns async service lifecycle. `Runtime/ServerRuntime.swift` composes
  `ServerHost` and `HTTPListener` and publishes `AppRuntimeSnapshot`.
- `Presentation/` holds UI-facing projections such as
  `AtmarkPresentationModel`, `MenuBarPresentation`, and
  `PermissionActionPresentation`.
- `MenuBar/` and `Settings/` contain feature views. Current entry views are
  `AtmarkMenuView` and `AtmarkSettingsView`; settings are split into focused pane
  and row files rather than one monolith.
- `SharedUI/` contains controls used across app surfaces; `PreviewSupport/`
  contains preview-only runtime support.

Keep backend DTOs and safety logic in `AtmarkCore`/`AtmarkServer`. Do not place
service ownership in a view, production behavior in preview support, or one-off
feature controls in `SharedUI`.
