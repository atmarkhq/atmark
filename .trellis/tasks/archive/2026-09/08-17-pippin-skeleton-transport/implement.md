# Skeleton and Transport — Execution Plan

Prerequisites resolved (`../08-17-pippin-mcp-server/addendum-2026-08-18.md` §1):
swift-sdk approved (O1); signing uses the fixed self-signed keychain identity, no
Developer ID, no notarization (O2); batch-one `tools/list` budget is 6 KB (O3).

Ordering: this child lands before `08-17-pippin-reminders-crud` and
`08-17-pippin-mail-read-search`, which consume the primitives from step 5.

## Checklist

### Step 0 — Verify the SDK surface  ✅ done 2026-08-23
- [x] Version resolved: **0.12.1** (latest tag). Every API confirmed against the
      cloned source, not documentation. Full record:
      `research/swift-sdk-surface.md`.
- [x] Throwaway probe compiles and runs under Swift 6 language mode on
      `.macOS(.v26)`.
- [x] **Stop condition cleared.** Per-request session identity *is* exposed —
      `Server.currentHandlerContext.httpContext: HTTPRequest?` inside handlers,
      and per-session `Server` construction besides. Parent A2 stands unchanged;
      no confirm-token redesign needed.
- [x] Two corrections folded into the parent `design.md` §2 and `prd.md` O1:
      the transport takes no port/host (the listener is ours — new open decision
      **O4**), and one transport serves exactly one session, so many clients means
      a `sessionID → (Server, transport)` table over one shared state core.

### Step 1 — Package skeleton  ✅ done 2026-08-23
- [x] `Package.swift`: tools `6.2` (`.macOS(.v26)` is unavailable at 6.1), five
      targets plus two test targets, `swiftLanguageModes: [.v6]`. swift-sdk pinned
      `exact: "0.12.1"`; swift-nio `from: "2.101.3"` on `PippinServer` only (O4).
      `Package.resolved` committed.
- [x] `PippinCore` import boundary enforced two ways: the dependency graph makes
      MCP and NIO unreachable, and `ImportBoundaryTests` scans the sources for
      SwiftUI / AppKit / Cocoa, which the graph cannot block. Negative case
      verified — adding `import SwiftUI` to `PippinCore` fails the suite.
- [x] Validation: `swift build` and `swift test` both green (3 tests, 2 suites).
- Carried to later steps: use `Tool.Content.text(text:annotations:_meta:)`; the
  bare `.text("…")` form is deprecated in 0.12.1.
- Deliberately deferred: `PippinApp` is a minimal `MenuBarExtra` with Quit — just
  enough for step 2 to produce a launchable bundle. The real status UI is step 8.
  `pippin-shim` exits with a "not implemented (step 7)" message.

### Step 2 — Packaging and signing  ✅ done 2026-08-23 · gate G1 passed
- [x] Adapt `setup_dev_signing.sh` from `apple-skills:guide-macos-spm-packaging`
      for the self-signed path only; make it idempotent and refuse to overwrite an
      existing identity. Drop the Developer ID and notarization branches — they
      are permanently out of scope, and dead signing code here is a live footgun.
- [x] Adapt `package_app.sh` with `MENU_BAR_APP=1`, `version.env`, and the full
      `Info.plist` key set; place `pippin-shim` inside the bundle.
- [x] Adapt `compile_and_run.sh`.
- Validation:
  ```bash
  Scripts/package_app.sh
  ls -R build/Pippin.app/Contents
  codesign -dv --verbose=4 build/Pippin.app
  ```
- **Review gate G1: PASSED.** Evidence in `research/g1-signing-verification.md`;
  the identity and its designated requirement are recorded in the repo-root
  `notice.md`. Three `rm -rf build && package_app.sh` cycles produced an
  identical `Authority`, `Identifier`, and designated requirement
  (`identifier "io.github.is52hertz.pippin" and certificate root =
  H"1ab7e0bc…775d"`), signed by `1AB7E0BC58C427092143FBADABA7F34CD607775D` every
  time. `codesign --verify --deep --strict` passes and the bundle launches.
  Also verified: with no identity present the packaging script exits 1 without
  building, re-running the signing script refuses to overwrite, and no key
  material survives under `$TMPDIR`. Caveat recorded — `spctl` proved nothing on
  this machine, where Gatekeeper assessment is disabled.

### Step 3 — Config and core error/DTO plumbing  ✅ done 2026-08-23
- [x] `Config`: defaults (writes off, escape hatch closed), snake_case wire form,
      load/save, loopback-bind validation via `inet_pton`. A corrupt file is an
      error, not a silent reset — discarding it would discard the write gates.
- [x] `PippinError`: the parent's ten codes, each with a non-empty actionable
      hint; wire form matches the design byte for byte; absent `detail` pruned.
- [x] DTO conventions: `JSONValue` with recursive pruning that keeps `false` and
      `0`, ISO-8601 with explicit offset, opaque-cursor pagination with a
      server-side cap.
- [x] Validation: `swift test` — **47 tests in 6 suites, all passing.** Covers
      non-loopback refusal (including `localhost` and `0.0.0.0`), pruning
      (including the falsy-value trap), hint coverage across every code, and
      pagination termination end to end.

### Step 4 — Server, transport, validators  ✅ done 2026-08-23
- [x] `ServerHost` actor: shared core (config, token store, registry) plus the
      session table `sessionID → (Server, transport, token, capabilities)`, with a
      timeout sweep and DELETE close.
- [x] HTTP listener on swift-nio bound to `127.0.0.1` (O4), ephemeral-port
      fallback on conflict, SSE piped from `HTTPResponse.stream`. Loopback is
      re-checked at bind time, not just at config load.
- [x] `TokenStore`: token → `TokenIdentity { label, capabilities }`. One local
      token provisioned with all three capabilities; the capability set is
      threaded into the registry. AC11 / S9.
- [x] Bearer and Origin validators. Sessions are additionally bound to the token
      that opened them, so a broad token cannot be swapped for a narrow one
      mid-session while keeping the broad tier.
- [x] `endpoint.json` published at mode 0600, with a `pid` and an `isStale` check
      — a crash or `kill -9` leaves the file behind, so readers must verify rather
      than dial a dead port.
- [x] `pippin_status` registered and answering over the wire.
- [x] Validation — live against the packaged bundle:
      correct token `200`; wrong token `401`; absent token `401`;
      `Origin: https://evil.example.com` `403`; loopback `Origin` `200`.
      Full handshake returns `pippin_status` in `tools/list` with its annotations
      and `outputSchema`, and `tools/call` returns the structured snapshot. AC5.
      Plus the two-token capability test from AC11. `swift test`: 85 tests,
      11 suites, all passing.

### Step 5 — Core safety primitives  ✅ done 2026-08-23 · gate G2 passed
- [x] `ConfirmTokenStore`: mint / validate / consume, TTL, single-use, SHA-256
      ID-set binding (order-independent), session binding, tool binding, item cap.
- [x] `MutationGate`, `AuditLog` (JSONL, 0600, one-generation rotation, argument
      digests only).
- [x] `AppleScriptRunner`: values via `on run argv`, never interpolated;
      wall-clock timeout with SIGTERM then SIGKILL.
- [x] `SQLiteReader`: read-only + `immutable=1`, dynamic versioned-path
      resolution (numeric, so V10 beats V9), schema probe that disables the
      backend on mismatch, bound parameters only.
- [x] `BackendRouter`: ordered backends, degradation marker with a reason, and it
      throws rather than ever returning empty.
- [x] `ToolContext` — **added by the G2 review**. The six primitives were
      individually complete and collectively unusable: nothing carried
      `sessionID` into a module handler, which A2's session binding is defined in
      terms of. It also absorbs the whole two-phase delete protocol
      (`confirmDestructive`), so the guarantees hold by construction rather than
      by each module remembering five checks and three audit calls.
- [x] Validation: `swift test` — **151 tests in 18 suites, all passing.**
      Injection payloads run through real `osascript` and real SQLite and are
      inert; a 10-second script under a 600 ms timeout returns in ~0.6 s; a failed
      schema probe never yields zero rows; every routing failure throws.
- **Review gate G2: PASSED.** Frozen API surface, what the review changed, and
  the four bugs it surfaced are recorded in
  `research/g2-primitive-api-freeze.md`.

### Step 6 — Tool registry and gating  ✅ done 2026-08-23
- [x] **Already existed (landed with step 4, retained unchanged):**
      `(Config, Capabilities) → [Tool]` as a pure function, with disabled-module,
      writes-off, and caller-capability gating covered by unit tests.
- [x] **New:** one `ProductionToolCatalogue` is consumed by both `PippinApp` and
      the budget suite. It intentionally contains only `pippin_status`; no module
      stubs were added.
- [x] **New:** `ServerHost.updateConfig` validates before replacing shared state,
      re-derives each session's visible list, and sends
      `notifications/tools/list_changed` to every affected active session.
      Persistence remains owned by `Config.save` rather than the server actor.
- [x] **New:** reusable production-catalogue budget coverage enforces a serialized
      `tools/list` response ≤ 6 KiB, descriptions ≤ 200 characters, and the
      long-term count ceiling of 40 tools.
- [x] **Validation:** `swift build` passed; `swift test` passed with **156 tests
      in 19 suites**. A test-only synthetic catalogue proves module/write gating.
      A live SDK transport test opens three MCP sessions and their standalone SSE
      streams, then proves both affected full-capability sessions receive
      `ToolListChangedNotification` while the unaffected read-only session does
      not.
- Actual Reminders/Mail disappearance cannot be exercised until those module
  catalogues exist; it remains an integration check for their module work and
  step 9. No packaged-bundle module tool was fabricated for this step.

### Step 7 — Shim  ✅ done 2026-08-23
- [x] First follow the source-level contract in
      `research/shim-transport-surface.md` (swift-sdk 0.12.1): use raw
      `StdioTransport` + `HTTPClientTransport` rather than typed `Client` /
      `Server`, because the SDK exposes no wildcard proxy.
- [x] Read and validate `endpoint.json`. If missing, malformed, stale, or
      unreachable, launch the fixed bundle ID `io.github.is52hertz.pippin` via
      `/usr/bin/open -b`, then wait for a fresh authenticated endpoint under one
      bounded readiness deadline.
- [x] Relay JSON-RPC `Data` frames without interpreting or rewriting their
      business content, while converting stdio newline framing, HTTP POSTs, SSE
      events, and `MCP-Session-Id` framing. Preserve initialize ordering, then
      permit bounded concurrent POSTs so a long-running request cannot block
      cancellation or another request.
- [x] Hold only per-process ephemeral transport/session state. Keep the bearer
      token in memory only and never log/output it. Supervise resident liveness;
      on normal stdin EOF, use a bounded drain grace, cancel any stuck POST, and
      best-effort DELETE the MCP session before disconnect.
- [x] Distinct actionable nonzero exits for endpoint missing/malformed/stale,
      launch failure, readiness timeout, authentication failure, connection
      failure, runtime resident death, and stdio/output failure. No path hangs.
- [x] Tests: unchanged payload round-trip; session capture/reuse/termination;
      JSON, 202, POST-SSE, multi-event and split-chunk SSE; endpoint
      missing/malformed/stale; launch/readiness timeout; authentication and
      connection failure; long-running POST does not block cancellation.
- Validation this round: protocol-level tests plus a Codex stdio smoke test and
  direct-HTTP vs shim `tools/list` parity. Claude Code remains AC3's final client
  but its real smoke test is deferred to step 9 while organization access is
  externally disabled; that block is not a Pippin failure.
- Evidence: `research/step7-shim-verification.md`. `swift test` passed 172 tests
  in 22 suites. Codex launched the signed bundle's shim over stdio and called
  `pippin_status`; the direct-HTTP parity test observed the same `tools/list`.

### Step 8 — GUI
- [x] Add a non-prompting permission provider and compact permission DTO. Report
      Reminders from EventKit, per-target Mail Automation only when Mail is
      already running, and effective read access to the existing Mail data
      directory. Never launch an app or request permission while rendering
      status. Inject the provider so tests never touch TCC.
- [x] Extend `pippin_status` and its output schema with `permissions`; cover every
      state mapping and deterministic structured output in tests.
- [x] Replace the placeholder menu with a standard-control `MenuBarExtra` showing
      server state, bound port, session count, permission rows, and modules.
- [x] Add a dedicated Settings window with module enable/write toggles. Persist a
      validated config before applying it to the resident host; surface failures
      without advancing the UI mirror. Verify a visible-tool change emits
      `notifications/tools/list_changed` through the existing server path.
- [x] Add buttons opening the relevant Privacy & Security panes. Label the
      target-specific Apple Events row "Mail Automation" and the effective FDA
      probe "Mail Data" so the UI does not overstate what macOS exposes.
- [x] Add focused tests for permission mapping, status serialization, config
      update success/failure, and UI-model state transitions. Package the signed
      app and manually verify menu-bar-only (`LSUIElement`) behaviour, Settings /
      Command-comma, standard controls/materials, light/dark appearance, and that
      opening/refreshing the UI causes no TCC prompt.
- Validation: consult `apple-skills:hig` and `apple-skills:ios-liquid-glass`,
      then review against them. AC7, AC10.

Automated and source-level evidence is recorded in
`research/step8-gui-verification.md`. The focused tests, signed package,
LaunchServices `UIElement` classification, live `pippin_status`, non-launch of
Mail, source review, and independent Trellis check all pass. A user visual review
on 2026-08-23 confirmed that the menu now renders after the zero-height fix, but
**rejected the UI as non-HIG-compliant and visually unfinished**: the menu is
over-dense and clips its lower content, while Settings is oversized, has
unbalanced empty space, and isolates Refresh as a floating centered control.
AC10 and the final Step 8 box therefore remain open. The screenshots are local
temporary artifacts and are described, not copied into the public repository.

Before redesign, the functional manual checks were: scroll the menu to
its action row; open Settings from both `Settings…` and Command-comma; verify a
module enable toggle persists after closing/reopening and restore it; verify all
three privacy buttons route to the intended panes without changing grants; and
verify Refresh neither prompts for TCC nor launches Mail. The later visual pass
must address hierarchy, density, window sizing, toolbar placement, and both
appearances before AC10 can close.

Manual functional result (2026-08-23): scrolling/action-row reachability,
module-toggle persistence, and Refresh all pass. Settings opens from both entry
points, but an already-open Settings window is not activated or raised — a real
`LSUIElement` activation bug. Privacy deep links reach the intended panes, but
Reminders and Automation do not list Pippin because the app has never made an
explicit first authorization request; navigation alone cannot register a TCC
entry. Mail Data was not changed in this run and still reflects the grant made in
the previous run. This pre-fix result kept Step 8 open until Settings activation
and permission onboarding were implemented and rerun below.

Approved functional clarification (2026-08-23; Settings shell updated 2026-08-25):

- Replace both native Settings entry points with one semantic
  `OpenWindowAction` control, replace `.appSettings` for Command-comma, and call
  modern `NSApp.activate()` before opening/raising the fixed-ID ordinary Settings
  window. Do not use window-title discovery or deprecated activation APIs.
- Keep `PermissionProviding`, every `ServerHost` snapshot, `pippin_status`, UI
  appearance refresh, and explicit Refresh strictly read-only and nonprompting.
- Add a separate user-action interface implemented by
  `SystemPermissionProvider`; route it through `ServerRuntime` and the shared
  presentation model so views own no EventKit, Apple Events, workspace, or
  System Settings behavior.
- Reminders requests full access only from a `not_determined` **Request
  Access…** click; denied/restricted routes to the Reminders privacy pane.
- Mail Automation `unavailable` offers **Open Mail…** and launches only
  `com.apple.mail` with modern `NSWorkspace`; `not_determined` offers a separate
  **Request Access…** that calls the prompting Apple Events determination off
  the main actor; denied/restricted routes to Automation.
- Mail Data never offers a request. Its button is **Open Full Disk Access…**,
  explains manual addition, and only opens that pane.
- Expose one in-progress action to suppress duplicate clicks. On success or
  failure, refresh the authoritative read-only snapshot; surface actionable
  failure text without synthesizing a permission state.
- Add behavior tests for state-to-action routing, runtime/model success and
  failure transitions, passive nonprompting isolation, and request-result /
  OSStatus mappings. No source-scan or view-tautology tests.

This patch intentionally leaves the visual redesign and AC10 open. It does not
add module tools, Step 9 work, dependencies, or signing changes.

Functional implementation result (2026-08-24): the Settings activation path,
state-specific onboarding actions, strict passive/action protocol split,
single-flight presentation state, and refreshed failure handling are implemented.
`swift build` passes; `swift test` passes 193 tests in 24 suites; and
`git diff --check` passes. The added regressions exercise state-to-action
routing, runtime/model success and failure, duplicate suppression, request-result
mapping, passive refresh isolation, and a real MCP `pippin_status` call through
the passive boundary. The signed-app rerun passed both Settings entry points,
Reminders onboarding, Mail launch followed by separate Automation onboarding,
and Full Disk Access navigation. A subsequent passive status call reported all
three effective states as `granted`. The visual redesign and AC10 remain
separate and open.

Approved visual-redesign plan (2026-08-24):

- [x] **8A — Pure source migration.** Move the existing app files into the lean
      `App/Runtime/Presentation/MenuBar/Settings/SharedUI` structure defined in
      `research/step8-ui-architecture.md`. Make no behavior or visual change.
      Verify build, tests, signed packaging, unchanged identity, and no fresh TCC
      prompt. Commit independently as
      `refactor(app): organize app UI sources`.
- [x] **8B — Menu-bar redesign.** Replace the developer dashboard with the
      compact user hierarchy, actionable-problems-only body, automatic refresh,
      and semantic icon states. Do not implement server lifecycle. Commit
      independently as `feat(app): redesign menu bar experience`.
- [x] **8C — Settings redesign.** Add the standard sidebar/pane information
      architecture as real content warrants, move diagnostics to Advanced, use
      user-facing integration language, and adopt compact responsive sizing.
      A disabled read-only global server switch may mirror the actual running
      state; it has no setter, persistence, or runtime behavior. The separate
      lifecycle task owns that feature. Commit independently as
      `feat(app): redesign settings experience`.
- [x] **8D — Close AC10.** Add semantic presentation-state tests and useful
      previews for ready, needs-attention, setup-required, and failed. Avoid
      pixel/layout tests and source-string tautologies. Run build/test/package/
      diff-check, then manually review the signed app in light and dark modes,
      menu-bar interaction, Settings activation, and window resizing. VoiceOver
      manual testing was explicitly deferred by the user and is not claimed as
      completed evidence. Finish with an independent `trellis-check`.

Approved Settings shell correction (2026-08-25; Relay approach):

- Replace SwiftUI's `Settings` scene with one ordinary `Window` under a fixed ID.
  Suppress default launch and use content-minimum resizability so `LSUIElement`
  startup remains menu-bar-only while the compact window can resize normally.
- Route both `Settings…` and Command-comma through the shared
  `PippinSettingsButton` using `OpenWindowAction`. Activate with modern
  `NSApp.activate()` before opening the fixed ID so an existing instance is
  activated and raised; never discover it by title or use deprecated activation.
- Keep the root `NavigationSplitView` sidebar visible by default and bind its
  visibility to local view state so the standard sidebar toggle remains
  functional. Use Relay's minimal zero-size toolbar-item technique to request
  SwiftUI's standard unified toolbar/titlebar. Add no custom chrome.
- Preserve the disabled read-only MCP Server placeholder and every existing
  permission, module, server, menu, signing, dependency, and preview behavior.
  Automated coverage remains limited to valid source/import boundaries and pure
  presentation contracts; no pixel or source-string tests.

Final Step 8D result (2026-08-25): deterministic DEBUG-only previews cover
ready, needs-attention, setup-required, and failed menu states plus Settings;
Release contains none of their fixtures or symbols. The signed app remained
menu-bar-only at launch. User testing passed both Settings entry points, raising
the existing window, close/reopen, minimize/restore, standard traffic lights,
light and dark appearance, resizing, and the system sidebar control in both
directions. The ordinary fixed-ID Settings window uses only system controls and
materials. VoiceOver manual testing is explicitly deferred by the user rather
than reported as passed. Automated build/test/release/package/signature checks
passed. The final independent Trellis review found no implementation defects and
made only evidence-record consistency fixes, closing AC10 and Step 8.

The visual work must not add production module tools, Step 9 behavior, a new
dependency, signing changes, or the real server switch. Step 9 may proceed on
the existing transport contract independently of the planned lifecycle child.

### Step 9 — Integration and full-scope check
- [x] Connect Claude Code over HTTP and over the shim; confirm identical tool
      lists. AC3. Verified 2026-09-04: Claude Code (CLI 2.1.259, user session,
      logged in) connected as `atmark-http` (direct Streamable HTTP, port 51969)
      and `atmark-shim` (bundled stdio shim). Both listed exactly `atmark_status`
      — the post-rename `pippin_status` — and its output (version 0.1.0, port
      51969, permission snapshot) was field-identical across the two transports.
      Agent-side protocol pre-checks (401 without token, 200 with token, shim
      stdio handshake) ran first with no LLM tokens. Evidence in
      `research/step9-integration-verification.md`.
- [x] Two concurrent clients, one process, shared state, config change observed
      by both. AC4.
- [x] Three rebuild-repackage cycles with no fresh TCC prompt. AC2.
- [x] Re-run the whole acceptance list; record results in the manual checklist
      derived from `Test/templates-test-checklist.html`.

Partial Step 9 result (2026-08-28; TCC confirmation added 2026-08-29): all non-Claude automated and live transport
checks pass. Three consecutive package/sign cycles produced byte-identical
certificate fingerprints and designated requirements. The final signed bundle
retained passive Reminders and Mail Data access. The user confirmed that none of
the three cycles produced a fresh Reminders, Automation, or Full Disk Access
prompt, closing AC2.

Two bundled shim clients simultaneously held distinct MCP sessions while one
resident signed Pippin process reported `sessions=2`; both clients observed the
same tool list and module state. The existing real SDK integration test was
rerun and proved shared config updates plus `tools/list_changed` propagation to
both affected sessions. Codex independently called `pippin_status` through the
bundled shim and direct Streamable HTTP, both reporting version 0.1.0. The HTTP
credential existed only in the invocation's environment and was absent from
arguments, persistent config, stdout, stderr, and evidence.

Claude Code 2.1.250 is installed but currently reports `loggedIn=false`; no
Anthropic API key is available. Pippin did not attempt login or alter Claude
configuration. AC3 and the first Step 9 item remain externally blocked rather
than failed. Full evidence and the public-safe checklist are in
`research/step9-integration-verification.md` and
`research/step9-acceptance-checklist.html`.

Step 9 closed 2026-09-04: the external blocker was resolved by the user logging
Claude Code in on their own account; AC3 passed a live dual-transport test (see
the research file's update section). All eleven ACs now pass and the task is
ready for archive.

## Validation Commands

```bash
swift build
swift test
Scripts/package_app.sh
codesign -dv --verbose=4 build/Pippin.app
spctl --assess --type execute --verbose build/Pippin.app
```

## Rollback Points

- After step 2: packaging is independent of server code; a bad packaging change
  reverts without touching Swift sources.
- After step 5 (gate G2): the last point where primitive APIs are cheap to
  change. Past here, changes ripple into both module children.
- Steps 7 and 8 are independent of each other; either can revert alone.

## Notes

- Every permission-dependent validation runs against the packaged bundle, never
  `swift run`.
- Do not add module tools here, not even a stub. `pippin_status` is the only tool
  in scope.
