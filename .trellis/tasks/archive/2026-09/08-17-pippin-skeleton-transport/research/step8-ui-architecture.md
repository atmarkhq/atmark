# Step 8 HIG Redesign — Approved Architecture and Scope

Decision record for the remaining visual portion of Step 8. It consolidates the
user's screenshots, manual functional results, and the external read-only Fable
review. It authorizes planning, not implementation of new server behavior.

## 1. Scope Boundary

The current functional permission onboarding, module configuration, Settings
activation, resident runtime, and transport behavior stay intact. The redesign
changes source organization and presentation only.

A global **MCP Server** switch may be shown as a disabled, read-only placeholder
because Pippin remains development-only and will not ship before
`08-24-pippin-server-lifecycle-toggle` lands. The placeholder:

- reflects the actual `model.state == .running` value;
- has no setter, persistence, lifecycle side effect, or fake local state;
- is visibly disabled and cannot imply that clicking it works;
- is removed/replaced when the lifecycle feature lands.

No concrete server-toggle behavior, production module tool, dependency, signing
change, or Step 9 transport work belongs in the visual redesign.

## 2. Lean Source Layout

Move the existing `PippinApp` target into this shape without adding a new SwiftPM
target:

```
Sources/PippinApp/
├── App/
│   ├── PippinApp.swift
│   └── AppDelegate.swift
├── Runtime/
│   └── ServerRuntime.swift
├── Presentation/
│   ├── PippinPresentationModel.swift
│   └── PermissionPresentation.swift
├── MenuBar/
│   └── PippinMenuView.swift
├── Settings/
│   └── PippinSettingsView.swift
└── SharedUI/
    ├── PermissionActionControl.swift
    └── PippinSettingsButton.swift
```

Rules:

- The first migration is file movement only: zero behavior and zero visual
  changes.
- Keep actor, runtime protocol, state, and snapshot together in
  `ServerRuntime.swift`; do not fragment one coherent runtime into tiny files.
- Keep one shared `@MainActor @Observable` presentation model. Settings
  navigation selection remains local (`@State` or `@SceneStorage`).
- `SharedUI` accepts only a component used by at least two presentation surfaces.
- `PreviewSupport/PreviewRuntime.swift` is added only when real previews require
  it and prove useful.
- Do not pre-create `Features/`, empty Settings-pane directories, `Resources/`,
  `PippinUI`, or `PippinAppCore`. Resource ownership is a future packaging
  decision.
- `Runtime` imports no SwiftUI. MenuBar/Settings/SharedUI import no EventKit,
  Carbon, NIO, or MCP. Add a modest import-boundary test where it protects these
  facts; avoid brittle scans for arbitrary symbol strings.
- Keep the synchronous `Endpoint.remove()` in `applicationWillTerminate`; do
  not replace it with an async `runtime.stop()` that macOS need not await.

Before a generic integrations UI expands beyond the two current modules, define
an `IntegrationDescriptor` contract. Backend/module code owns stable ID,
capabilities, and permission requirements. Display names, localization, and SF
Symbols are presentation concerns and must not be pushed blindly into backend
types.

## 3. Menu Bar Information Architecture

The menu-bar window is a user surface, not a server dashboard.

- Retain the `.window` MenuBarExtra style, about 300–320 pt wide with adaptive
  height and no clipped scroll-to-actions requirement.
- Header: Pippin, concise service status, and the disabled read-only global
  switch placeholder.
- Body: show **Needs Attention** only when an enabled integration needs a user
  action. Do not list healthy permissions or development diagnostics by default.
- Footer: manage apps/open Settings and Quit. Refresh is automatic on open and
  after an action, not a prominent button.
- Do not show bound address, port, session count, raw backend names, or write
  terminology in this surface.

Menu-bar icon semantics:

| Condition | Icon treatment |
|---|---|
| Running with at least one usable integration | Normal |
| Running with partial permission issues | Warning badge |
| Server off, or zero usable enabled integrations | Slash / setup-required |
| Startup/runtime failure | Warning/error treatment |

## 4. Settings Information Architecture

Use standard macOS Settings structure: system sidebar, toolbar/window chrome,
`Form`, `Section`, `Toggle`, `Button`, and system materials. macOS 26 supplies
Liquid Glass to system surfaces; do not apply decorative glass to content.

Planned panes are created only when each has real content:

- **General:** service status and disabled read-only server placeholder in this
  visual round.
- **Apps / Integrations:** a data-driven list of enabled integrations and their
  controls. Use user language such as **Allow Changes**, not `Writes on`.
- **Privacy:** honest permission states, explanations, and the existing
  state-specific actions.
- **Advanced:** address, port, session count, and diagnostics now removed from
  the menu surface.
- **About:** app/version/GitHub/license only when backed by real values.

Target a compact starting window around 720 × 500 pt, with pane-responsive
sizing rather than one oversized fixed frame. Avoid hand-drawn cards, custom
window chrome, ornamental empty space, and a floating centered Refresh button.

## 5. Delivery and Verification

Keep the work in independently reviewable units:

1. `refactor(app): organize app UI sources` — pure file migration; build, test,
   package, verify signature and no fresh TCC prompt.
2. `feat(app): redesign menu bar experience` — menu hierarchy and icon states.
3. `feat(app): redesign settings experience` — sidebar/panes and responsive
   sizing.

Close AC10 only after:

- previews cover ready, needs-attention, setup-required, and failed states;
- presentation tests cover semantic state derivation, not pixel layout or
  source-string tautologies;
- `swift build`, `swift test`, signed packaging, and `git diff --check` pass;
- the signed app is manually reviewed in light/dark appearance, menu-bar
  interaction, Settings/Command-comma activation, and compact window resizing;
- VoiceOver manual testing is explicitly deferred by the user and remains
  untested; semantic labels and automated presentation tests must not be
  presented as a substitute for that future pass;
- an independent `trellis-check` passes.
