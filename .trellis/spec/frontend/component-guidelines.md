# SwiftUI Component Guidelines

- Compose scenes at `AtmarkApp`: the menu bar receives
  `AtmarkMenuView(model: delegate.model)` and the Settings window receives
  `AtmarkSettingsView(model: delegate.model)`. Pass the shared presentation model
  explicitly rather than resolving server globals inside views.
- Keep feature views under `MenuBar/` or `Settings/`; split settings by pane,
  section, and reusable row as the existing filenames demonstrate.
- Derive visible labels and symbols from presentation values. The menu-bar label
  uses `menuBarPresentation.accessibilityLabel` and `symbolName`, with
  `.labelStyle(.iconOnly)` preserving an accessible text label.
- Use native scene behavior deliberately: Settings has a stable window ID,
  suppressed default launch, a concrete default size, and content-minimum
  resizing; the Settings command uses the conventional Command-Comma shortcut.
- Keep async lifecycle and persistence out of `body`; views send intent to the
  presentation model and render its snapshot.

Avoid giant settings views, duplicated status-to-symbol logic, hidden service
singletons, and icon-only controls without an accessibility label.
