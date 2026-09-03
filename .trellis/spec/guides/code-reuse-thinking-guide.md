# Code Reuse Thinking Guide

Search before adding a helper, projection, constant, or second implementation of
an existing responsibility:

```bash
rg "symbol-or-behavior" Sources Tests
```

## Existing Sources of Truth

- `ProductionToolCatalogue.definitions` is the one production registration list;
  the app and `ToolSurfaceBudgetTests` both consume it.
- `ToolRegistry.tools` is the one visibility projection from `(Config,
  Capabilities)`. Transports and modules must not reproduce its filtering.
- `ToolContext.confirmDestructive` owns preview, token consumption, and audit
  sequencing for destructive operations.
- `AtmarkPresentationModel` owns status, permission-action, and settings-error
  projection shared by the menu and Settings window.
- `AtmarkSettingsButton` and `PermissionActionControl` are existing shared UI
  controls with real callers on more than one app surface.

## Extraction Rule

Keep a one-off operation inline. Extract it when a second real caller needs the
same behavior or when one stable contract must change atomically for all callers.
Two literals that merely match today are not automatically one concept.

Prefer named owners for stable concepts already present in the codebase, such as
`AtmarkWindow.settingsID`, `StatusTool.name`, and
`ConfirmTokenStore.maximumItemsPerCall`. Do not create a parallel constant in a
view, transport, or test fixture.

## Intentional Repetition

Do not deduplicate independent trust-boundary checks just because their code is
similar. `Config.validate` rejects non-loopback configuration before persistence,
while `HTTPListener.start` checks again at the point of binding. Both guards are
required so a refactor cannot silently widen the listener.

## Avoid

- Do not create a second production tool catalogue or a transport-specific
  visibility list.
- Do not copy status-to-label or permission-to-action switches into individual
  views.
- Do not wrap a single call in a speculative protocol, generic utility, or
  configuration flag.
- Do not move code into `AtmarkCore` merely to reuse it if that introduces MCP,
  NIO, SwiftUI, or AppKit imports.

## Review Checklist

- [ ] Searched `Sources/` and `Tests/` for the concept and its callers.
- [ ] Reused the existing owner when callers must change together.
- [ ] Preserved intentionally repeated boundary validation.
- [ ] Added no abstraction without a current second caller or stable contract.
- [ ] Updated every catalogue, projection, and test that consumes the changed
      source of truth.
