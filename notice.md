# Project Notice — Atmark

Durable, cross-task facts. Session progress does not belong here.

## Rename history

This project began inside a parent-directory project named iMCP, shipped under
the product name Pippin, and was renamed to Atmark on 2026-08-31 when the tree
migrated to this repository location. The rename changed the bundle ID and the
code-signing identity, which invalidated every prior TCC grant; one-time manual
re-granting was explicitly accepted. The full record lives in
`.trellis/tasks/08-31-atmark-rename`; historical task records keep the old
names verbatim by design, and this section is the only live document that may
use them.

## Signing identity — do not regenerate

Atmark.app is signed with a self-signed local identity. macOS keys TCC grants to
the code signature, so replacing this certificate silently invalidates every
permission the user has granted — it produces no error, only later failures that
look like bugs.

```
Identity    Atmark Local Signing
Bundle ID   io.github.atmarkhq.atmark
Created     2026-08-31 (rename), validity 7300 days
SHA-1       D636537074936D9266FA0FEA2175721C3E07B2A3
```

The designated requirement TCC matches on:

```
identifier "io.github.atmarkhq.atmark"
  and certificate root = H"d636537074936d9266fa0fea2175721c3e07b2a3"
```

The identity replaces the pre-rename one (still in the keychain, unused — see
Rename history); its creation is what killed the old grants.

Only two things are pinned: the bundle identifier and the certificate. The
binary's hash is not, so rebuilding freely is safe. Changing either of the two is
not, and neither is recoverable except by re-granting every permission by hand.

`Scripts/setup_dev_signing.sh` refuses to overwrite an existing identity and has
no `--force`. That is deliberate; do not add one.

## Packaging

- `Scripts/package_app.sh` → `build/Atmark.app`. Requires the identity above and
  **fails hard** if it is missing or ambiguous. There is no ad-hoc fallback, by
  design — an ad-hoc signature has no stable designated requirement.
- Hardened runtime is deliberately off. It exists to satisfy notarization, which
  is permanently out of scope (no paid Apple Developer account), and enabling it
  would impose an entitlement requirement on the Apple Events this app sends.
- Never validate permission-dependent behaviour via `swift run`. A bare
  executable has a different signature and bundle identity and does not inherit
  the app's TCC grants. Use `Scripts/compile_and_run.sh`.

## Dependencies

Two, both user-approved: `modelcontextprotocol/swift-sdk` (pinned `exact:
"0.12.1"` — pre-1.0, and its transport contract has been mapped in detail) and
`apple/swift-nio` (the MCP SDK ships no HTTP listener). Adding a third needs a
decision.

`AtmarkCore` must not import SwiftUI, AppKit, or the MCP SDK. The package graph
blocks the SDK and NIO; `Tests/AtmarkCoreTests/ImportBoundaryTests.swift` covers
the system frameworks.

## Tool surface

- `ProductionToolCatalogue` is the one production catalogue. App modules add
  their `ToolDefinition`s there; the app and the automated token-budget checks
  both consume that same source, so registration and budget accounting cannot
  drift apart.
- Tool visibility is derived purely from `(Config, Capabilities)`. A disabled
  module contributes nothing; writes-off contributes read-only tools only.
  Never add a present-but-refusing tool as a substitute for absence — it would
  remain in the recurring token budget and in the agent's candidate set.
- `ServerHost.updateConfig` validates before changing shared state and emits
  `notifications/tools/list_changed` only to sessions whose visible tool list
  actually changed. Persistence remains `Config.save`'s responsibility.
- Automated ceilings: serialized batch-one `tools/list` ≤ 6 KiB, each tool
  description ≤ 200 characters, and the long-term default catalogue ≤ 40 tools.

## Stdio shim transport

- `AtmarkShim` relays raw `Data` between swift-sdk 0.12.1's `StdioTransport`
  and `HTTPClientTransport`. Do not insert typed SDK `Client`/`Server` actors:
  they consume lifecycle messages and cannot transparently proxy unknown tools.
- The shim converts newline, HTTP POST, SSE-event, and `MCP-Session-Id` framing
  without decoding or rewriting JSON-RPC business content. It sequences the
  first two frames for initialize/initialized, then allows at most four POSTs
  concurrently.
- All shim state is scoped to one process/stdio connection. The endpoint,
  bearer token, session ID, SSE state, and requests are memory-only; the token
  must never enter logs, diagnostics, arguments, or environment variables.
  `AtmarkShim` must not import or access Apple/TCC data frameworks.
- Endpoint recovery validates a mode-0600 file, literal loopback host, port, and
  live PID, then launches only bundle ID `io.github.atmarkhq.atmark`. Startup
  waits are bounded; the `open` helper escalates TERM→KILL rather than hanging.
- On stdin EOF, accepted POSTs receive a two-second drain grace. The shim then
  cancels any remainder, sends best-effort authenticated DELETE for the session,
  and disconnects. Preserve the timeout and the regression tests when changing
  lifecycle code.

## GUI and permission reporting

- `SystemPermissionProvider` is non-prompting. Status rendering must never call
  an EventKit request-access API or launch another app.
- Keep that passive boundary separate from user onboarding:
  `PermissionProviding.currentPermissions()` is the only permission interface
  visible to `ServerHost` and `atmark_status`; explicit UI clicks route through
  `PermissionActionPerforming` via `ServerRuntime`. Never merge the protocols or
  infer a grant from a request result — re-read the passive snapshot afterward.
- Reminders reports `EKEventStore.authorizationStatus(for: .reminder)`. Mail
  Automation is target-specific and queried with
  `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` only when
  Mail already runs; otherwise it is `unavailable`.
- Permission onboarding is state-specific and user-initiated. Reminders
  `not_determined` requests full access; denied/restricted opens its privacy
  pane. Mail Automation `unavailable` may open only bundle ID `com.apple.mail`;
  after refresh, `not_determined` offers a separate prompting Apple Events call
  off `MainActor`. Denied/restricted opens Automation. Mail Data has no request
  API and only opens Full Disk Access with manual-add instructions.
- macOS exposes no ordinary-app API for global Full Disk Access state. Atmark's
  `full_disk_access` wire field is only an effective, read-only probe of the
  existing `~/Library/Mail` directory. The GUI deliberately labels it **Mail
  Data** and must not claim broader certainty.
- `ServerHost` receives a `PermissionProviding` dependency, so unit tests use a
  fixed snapshot and never touch live TCC. `atmark_status` is the only batch-one
  production tool and includes this compact permission snapshot.
- The menu and Settings share one `@MainActor @Observable` presentation mirror;
  resident actors remain authoritative. Settings updates validate and atomically
  save `Config`, then call `ServerHost.updateConfig`, and update the mirror only
  after both succeed. Preserve that order to avoid disk/runtime divergence.
- Use native SwiftUI controls and system surfaces. macOS 26 supplies Liquid
  Glass automatically; do not add custom chrome, hand-drawn backgrounds, or a
  manual glass effect to content.
- For this `LSUIElement` app, Settings is one fixed-ID ordinary SwiftUI `Window`,
  with default launch suppressed and content-minimum resizability. Both the menu
  Settings item and Command-comma use one `OpenWindowAction` control. Call modern
  `NSApp.activate()` before opening the fixed ID so the existing window is
  raised; do not use deprecated `activate(ignoringOtherApps:)` or search for the
  window by title.

## Secrets

The repository is public. `.gitignore` denies keys, certificates, keychains,
provisioning profiles, `build/`, and `endpoint.json` (which carries the server's
bearer token at runtime). `setup_dev_signing.sh` exports nothing; key material
lives only in a mode-0700 temp directory and is wiped by a trap.
