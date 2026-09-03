# Presentation Guidelines

Presentation types translate runtime/domain state into UI-ready values; views
should mostly compose those values.

- Keep runtime snapshots transport-neutral and `Sendable` (`AppRuntimeSnapshot`).
- Put status labels, SF Symbol names, permission copy/actions, and settings error
  projection under `Presentation/`, represented today by
  `AtmarkPresentationModel`, `MenuBarPresentation`, and
  `PermissionActionPresentation`.
- Convert `AtmarkError` to user-facing text at the application boundary using its
  actionable `hint`, as `ServerRuntime.userFacingDescription` does. Preserve the
  original thrown error for control flow and testing.
- Share one presentation model between `AtmarkMenuView` and
  `AtmarkSettingsView` so status and configuration do not diverge.

Do not show raw bearer/session/confirmation tokens, request bodies, SQLite data,
or arbitrary backend diagnostics. Do not duplicate domain validation or
capability decisions in presentation code.
