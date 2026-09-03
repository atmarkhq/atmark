# Skeleton and Transport — Technical Design

Inherits `../08-17-pippin-mcp-server/design.md`. This file covers only what is
specific to the skeleton child.

## 1. Package Layout

```swift
// Package.swift  (sketch — exact API confirmed against the SDK at implementation time)
platforms: [.macOS(.v26)]
swiftLanguageModes: [.v6]

targets:
  PippinCore     // no MCP, no SwiftUI imports — pure, unit-testable
  PippinModules  // depends on PippinCore
  PippinServer   // depends on PippinCore + PippinModules + MCP + NIO
  PippinApp      // executable; SwiftUI; depends on PippinServer
  pippin-shim    // executable; depends on MCP only
  PippinCoreTests, PippinServerTests
```

`PippinCore` must not import SwiftUI, AppKit, or the MCP SDK. That boundary is
what keeps the safety model (token store, mutation gate, routing, DTO shaping)
unit-testable without a GUI, a transport, or TCC.

## 2. Bundle Assembly and Signing

Adapt the templates from `apple-skills:guide-macos-spm-packaging` rather than
writing packaging from scratch:

- `Scripts/setup_dev_signing.sh` — create the long-lived signing identity once: a
  fixed self-signed keychain identity, since there is no paid Apple Developer
  account (parent O2). Run once per machine; the identity must then never be
  regenerated, since regenerating it is precisely what breaks TCC grants. The
  script is idempotent and refuses to overwrite an existing identity, because the
  destructive failure mode here is silent — a regenerated certificate does not
  error, it just quietly invalidates every permission the user has granted.
- `Scripts/package_app.sh` — build with `swift build -c release`, assemble
  `Pippin.app/Contents/{MacOS,Resources,Info.plist}`, sign with the stable
  identity. `MENU_BAR_APP=1` emits `LSUIElement`.
- `Scripts/compile_and_run.sh` — dev loop: kill the running instance, repackage,
  relaunch the bundle.
- `version.env` — `APP_NAME`, `BUNDLE_ID`, version, build number.

`Info.plist` keys: `LSUIElement=true`, stable `CFBundleIdentifier`,
`NSAppleEventsUsageDescription`, `NSRemindersFullAccessUsageDescription`.

The shim ships inside the bundle (`Contents/MacOS/pippin-shim`) so there is one
artifact to install, and clients point at that path.

## 3. Resident Server Wiring

`PippinApp` owns server lifetime. The server, the registry, the token store, and
the audit writer are held by a single actor so concurrent client requests
serialize through one owner — this is the mechanism behind parent criterion A4.

```
PippinApp (SwiftUI App)
  └── ServerHost (actor)
        ├── HTTPListener (swift-nio, bound 127.0.0.1)   ← O4
        ├── Sessions: sessionID → (Server, StatefulHTTPServerTransport)
        ├── ToolRegistry      (derived from Config)
        ├── ConfirmTokenStore (in-memory only; a restart invalidates every token)
        └── AuditLog
```

The SDK's transport binds no socket and serves exactly one session, so the
listener is ours (swift-nio, per O4) and clients get one `Server` each. Everything
below the session table is shared process state — that sharing is the whole point
of a resident process. See
`research/swift-sdk-surface.md`.

Confirm tokens intentionally live in memory only. A restarted server refusing a
token minted by its predecessor is the correct, conservative behaviour.

**Port selection:** try the configured port; on conflict, bind an ephemeral port.
Publish whatever was actually bound to `endpoint.json`. Never fail to start over
a port conflict.

**Validators** (via the SDK's `HTTPRequestValidator` pipeline):
1. bearer-token lookup → 401 on miss
2. `Origin` absent or loopback → otherwise reject

**Token model, shaped for tiers (S9).** Validation resolves a presented token to
a *capability set*, not to a boolean:

```
TokenStore: token → TokenIdentity { label, capabilities }
Capabilities: read | write | destructive        (a set, not a flag)
```

Batch one provisions exactly one token, whose capability set is "all three". The
registry already derives the tool list from `(config, capabilities)` rather than
from config alone, so batch four's remote read-only token needs a new row in the
store and nothing else. The cost today is one parameter threaded through the
registry; the cost of retrofitting it later is every call site that assumed a
single omnipotent caller.

This is intentionally *not* a permission system yet — no minting UI, no
revocation, no persistence of multiple tokens. Only the shape.

**Bind validation:** `config.http.bind` is parsed and required to be a loopback
address. Anything else is a startup error with an explicit message. Constraint C1
is enforced here, in code.

## 4. Shim Behaviour

```
1. read and validate ~/Library/Application Support/Pippin/endpoint.json
2. if missing, malformed, stale, or unreachable → launch bundle identifier
   io.github.is52hertz.pippin under a hard deadline; SIGTERM then SIGKILL the
   `open` helper if it fails to exit
3. poll a bounded authenticated readiness probe until a fresh endpoint responds
4. wrap this process's stdin/stdout with StdioTransport and connect
   HTTPClientTransport to the resident endpoint
5. relay raw JSON-RPC Data frames in both directions while converting newline,
   HTTP POST, SSE event, and session-header framing
6. supervise resident liveness; on normal EOF, give the already-accepted bounded
   POST queue a two-second drain grace, cancel any remainder, best-effort DELETE
   the MCP session, then disconnect
7. on any terminal failure → emit one distinct, actionable stderr diagnostic
   and exit non-zero
```

The shim does not interpret or rewrite JSON-RPC payload business content. It is
not a literal byte pipe: stdio, Streamable HTTP, and SSE have different framing,
so it must convert framing and hold the MCP session ID plus in-flight connection
state for the lifetime of one stdio connection.

That state is strictly ephemeral. The endpoint and bearer token live only in
memory (the token is never logged or written), and the session ID, SSE cursor,
readiness deadline, and in-flight HTTP tasks disappear when the shim exits. The
shim holds no shared or persistent business state, security decisions, Apple
data, TCC grant, cache, or audit log. The sole owner of those remains the
resident `Pippin.app` process.

Verified against swift-sdk 0.12.1 in
`research/shim-transport-surface.md`: `StdioTransport` and
`HTTPClientTransport` both expose raw `Data` frames and already implement newline
and HTTP/SSE/session framing respectively. The SDK has no generic proxy,
readiness probe, client-side DELETE, or reliable outward failure for its
background GET reconnect loop, so Pippin owns the two structured relay pumps,
bounded startup/readiness, runtime liveness supervision, and best-effort DELETE.
No additional dependency is needed.

## 5. Tool Registry

The registry is a pure function: `(Config, Capabilities) → [Tool]`. Testable with
no transport. Registration for each tool declares name, terse description
(≤ 200 characters), input schema, optional output schema, annotations, and
whether it is a write or destructive verb.

The `Capabilities` parameter is the S9 allowance. Batch one always passes the full
set, so behaviour is identical to `Config → [Tool]`; the parameter exists so that
a read-only token later yields a read-only tool list through the same code path
rather than a bolted-on filter.

Gating order: module disabled ⇒ contributes nothing; module enabled with writes
off ⇒ contributes read-only tools only. Absent, never present-and-erroring
(parent A6).

A config change recomputes the registry and emits
`notifications/tools/list_changed`.

## 6. Core Primitives Delivered Here

| Primitive | Responsibility | Key test |
|---|---|---|
| `Config` | load/save, defaults, loopback validation | non-loopback bind refused |
| `DTO` conventions | null pruning, ISO-8601, pagination/cursor | pruning drops empties |
| `PippinError` | code + detail + hint, compact encoding | every code has a hint |
| `MutationGate` | write-enabled check at call time | writes off ⇒ refusal |
| `ConfirmTokenStore` | mint, validate, consume | TTL / single-use / ID-set / session |
| `AuditLog` | append JSONL, rotate, digest args | no raw argument values written |
| `AppleScriptRunner` | Apple Event args, wall-clock timeout | injection attempt is inert |
| `SQLiteReader` | read-only open, schema probe | failed probe disables backend |
| `BackendRouter` | ordered backends + degradation | falls back, never empty-on-failure |

`AppleScriptRunner` and `SQLiteReader` are built here even though the skeleton
itself calls neither: the Mail child needs both, and the alternative — each
module rolling its own — is exactly how the injection and silent-empty-result
rules get violated.

## 7. GUI

The remaining HIG redesign follows
`research/step8-ui-architecture.md`; that decision record is authoritative for
source layout, visual scope, and delivery sequence. The functional permission
and config contracts below remain unchanged.

`MenuBarExtra` with a dedicated, fixed-ID ordinary `Window` for Settings. The
menu is the compact user surface; Settings owns module controls, full permission
explanations/actions, and advanced server diagnostics. The window suppresses
default launch and resizes down to its content minimum, preserving menu-bar-only
startup. Reading either surface must never prompt for access or launch another
app. The detailed final hierarchy appears below and in
`research/step8-ui-architecture.md`.

Permission reporting is deliberately narrower than the label "TCC status" can
suggest:

| Row / status key | Source | Honest states |
|---|---|---|
| Reminders / `reminders` | `EKEventStore.authorizationStatus(for: .reminder)` | `not_determined`, `denied`, `restricted`, `write_only`, `granted` |
| Mail Automation / `mail_automation` | `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` when Mail is already running | `not_determined`, `denied`, `granted`; `unavailable` when a non-prompting determination cannot be made |
| Mail Data / `full_disk_access` | read-only effective-access probe of the existing Mail data directory | `granted`, `denied`, `unavailable`, `unknown` |

macOS exposes no ordinary-app API for a global Full Disk Access status. The Mail
Data row therefore reports only whether Pippin can currently read the protected
Mail directory; it must not claim more. Apple Events permission is target-specific
and its non-prompting API requires the target to be running, so the UI says
"Mail Automation" rather than "Automation" and does not launch Mail merely to
produce a status.

The same compact permission snapshot is included in `pippin_status` under
`permissions`. Permission probes are injected into `ServerHost`, so server tests
use a deterministic provider and never touch TCC.

The settings source of truth remains `Config` on disk plus the resident
`ServerHost`. A toggle first validates and atomically saves the new config, then
calls `ServerHost.updateConfig`; only after both succeed does the UI mirror
advance. That update re-derives each session's visible registry and emits
`notifications/tools/list_changed` where the visible set changed. Failed saves
are shown to the user and leave the previous config active.

`PippinApp` owns one `@MainActor @Observable` model shared by the menu-bar and
dedicated Settings window. The resident runtime remains the owner of server
state; the UI model is only a presentation mirror. Permission and runtime
refreshes are explicit/on-appearance rather than a tight polling loop.

### User-initiated permission actions and Settings activation

The read boundary stays strict: `PermissionProviding` remains a read-only
dependency of `ServerHost`, and `currentPermissions()` must never request access
or launch another application. Explicit onboarding uses a separate
`PermissionActionPerforming` interface implemented by
`SystemPermissionProvider`. `ServerRuntime` routes those actions and returns a
fresh snapshot; `PippinPresentationModel` owns the in-progress and actionable
failure state. SwiftUI views select a model-provided semantic action and do not
call EventKit, Apple Events, `NSWorkspace`, or System Settings directly.

The approved action table is deliberately state-specific:

| Row state | User action |
|---|---|
| Reminders `not_determined` | **Request Access…** calls `requestFullAccessToReminders()`, then refreshes |
| Reminders `denied` / `restricted` | Open the Reminders privacy pane |
| Mail Automation `unavailable` | **Open Mail…** launches only `com.apple.mail` through `NSWorkspace.openApplication(at:configuration:)`, then refreshes |
| Mail Automation `not_determined` | A separate **Request Access…** calls `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: true)` off the main actor, then refreshes |
| Mail Automation `denied` / `restricted` | Open the Automation privacy pane |
| Mail Data (all states) | **Open Full Disk Access…** explains that Pippin must be added manually and only opens the Full Disk Access pane |

Each action is single-flight across the shared presentation model. A failed
action still refreshes the read-only snapshot before presenting an actionable
error, so the UI never infers or claims a grant from the request result.

For this `LSUIElement` app, the menu Settings item and Command-comma share one
semantic control backed by SwiftUI's `OpenWindowAction`. The app replaces the
`.appSettings` command group, declares one ordinary `Window` with a fixed
Settings ID, suppresses its default launch, and uses content-minimum
resizability. The control calls the modern `NSApp.activate()` before opening the
fixed ID, so SwiftUI activates or raises the same single window. It does not
search for a window by title and does not use deprecated
`activate(ignoringOtherApps:)`.

HIG compliance is a deliverable, not a polish pass: standard SwiftUI controls,
`Form`, `Section`, `Toggle`, `Button`, `OpenWindowAction`, system materials, no
hand-drawn backgrounds or custom window chrome. macOS 26 applies Liquid Glass to
standard controls and system surfaces automatically; Pippin does not apply a
glass effect to content. Consult `apple-skills:hig` and
`apple-skills:ios-liquid-glass` during implementation, not after.

### Presentation source layout and dependency rules

Use a lean single-target layout: `App/`, `Runtime/`, `Presentation/`,
`MenuBar/`, `Settings/`, and `SharedUI/`. Do not add a generic `Features/`
wrapper, empty future pane directories, or a separate UI target. Keep the
runtime actor and its protocol/state/snapshot coherent in one file; keep one
shared presentation model, with Settings navigation local to the scene.
`SharedUI` is only for controls used by both menu and Settings.

Runtime imports no SwiftUI. Presentation scenes import no EventKit, Carbon,
NIO, or MCP. Permission actions continue through semantic model intents. A pure
file migration precedes visual changes and must produce no behavior or visual
diff.

### Approved visual information architecture

The menu-bar window is compact and user-facing: concise status, only actionable
integration problems, Settings/manage-apps entry, and Quit. Address, port,
session count, backend diagnostics, and raw write terminology leave the menu.
Refresh happens automatically on appearance and after actions.

Settings uses a `NavigationSplitView` whose standard sidebar is visible by
default and remains user-toggleable through the standard sidebar control. A
zero-size system toolbar item, derived from Relay's shell approach, is the
smallest trigger that keeps the standard unified toolbar/titlebar; Pippin adds
no custom window chrome.
Real panes are created as content lands: General, Apps/Integrations, Privacy,
Advanced, and About. General may show a disabled read-only **MCP Server** switch
whose value mirrors the actual running state. It has no setter or side effect in
Step 8; the separate `08-24-pippin-server-lifecycle-toggle` task owns persistence
and runtime wiring. This placeholder is acceptable only while the app is
development-only.

The starting window should be compact (approximately 720 × 500 pt) and
pane-responsive. Do not hand-draw cards or chrome, decorate content with glass,
or retain a floating Refresh control. Full states, icon semantics, and AC10
evidence are specified in the research decision record.

## 8. Risks

| Risk | Handling |
|---|---|
| SDK API differs from the sketches here | Confirm against the real SDK before writing; treat these snippets as intent, not contract |
| SwiftUI App lifecycle misbehaves in a SwiftPM executable | Always run the packaged bundle; unbundled runs have wrong activation policy and signature |
| TCC prompt attributed to a parent process instead of the app | The app is the only process touching user data and it self-launches; the shim needs no grants |
| Port conflict at startup | Ephemeral fallback, publish the actual port |
| Signing identity accidentally regenerated | `setup_dev_signing.sh` is idempotent and refuses to overwrite an existing identity |
