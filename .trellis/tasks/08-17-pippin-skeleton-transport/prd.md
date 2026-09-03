# Pippin: .app Skeleton and Transport Layer

Child of `08-17-pippin-mcp-server`. Read the parent's `prd.md` and `design.md`
first — the decided design positions there are inherited, not up for revision.

## Goal

Stand up the process that everything else lives inside: a signed, TCC-stable
`Pippin.app` that hosts one resident MCP server, serves loopback Streamable
HTTP, ships a stdio shim for stdio-only clients, presents a HIG-compliant menu
bar UI, and provides the cross-cutting primitives the module tasks consume.

This child exists to retire the two highest-risk unknowns in the whole project —
TCC identity stability and the transport topology — before any module code is
written against them.

## Requirements

- **S1 — SwiftPM project skeleton.** `Package.swift` with the target layout from
  the parent design (`PippinCore`, `PippinModules`, `PippinServer`, `PippinApp`,
  `pippin-shim`), Swift 6 language mode, macOS 26 SDK.
- **S2 — Bundle packaging and stable signing.** Scripts that assemble
  `Pippin.app` from SwiftPM build products and sign it with a long-lived
  identity. `Info.plist` carries `LSUIElement`, a stable bundle identifier, and
  the Apple Events + Reminders usage descriptions. Not sandboxed.
- **S3 — Resident MCP server.** `StatefulHTTPServerTransport` bound to
  `127.0.0.1`, with bearer-token and Origin validators. Loopback binding
  validated in code.
- **S4 — Endpoint publication and shim.** `endpoint.json` (mode `0600`) carrying
  port and token. `pippin-shim` reads it, bridges `StdioTransport` to the HTTP
  endpoint, launches the app if it is not running, and fails with an actionable
  message on timeout rather than hanging. The shim holds no shared or persistent
  business state, security decisions, or Apple data. During one stdio
  connection, it may hold only the ephemeral transport/session state required
  to convert framing: the endpoint, the bearer token in memory (never logged),
  the MCP session ID, and in-flight HTTP/SSE connection state. All of it
  disappears when the shim exits.
- **S5 — Tool registry with gating.** Modules and their write capability are
  enabled per config. Disabled means absent from `tools/list`. Config changes
  re-derive the registry and emit `notifications/tools/list_changed`.
- **S6 — Menu bar GUI and Settings, HIG-compliant.** A compact, user-facing
  `MenuBarExtra` shows concise service health and only permission/integration
  problems that need action; development diagnostics such as bound port and
  session count belong in Settings. A dedicated Settings window manages modules
  and their write capability, permissions, diagnostics, and app information
  using standard controls and system materials only, with no custom-drawn chrome.
  Built against the macOS 26 SDK so the system Liquid Glass appearance applies.
  While the app remains development-only, both surfaces may show a disabled,
  read-only global server-switch placeholder; the separate lifecycle child owns
  its behavior before production use.
- **S7 — Cross-cutting core primitives.** Owned here because all modules consume
  them and duplicating them across module tasks would fragment the safety model:
  config loading, DTO conventions and null-pruning, the error model, the mutation
  gate, the confirm-token store, the audit-log writer, the AppleScript runner
  (parameterized + timeout), the read-only SQLite reader, and backend routing.
- **S8 — One proof tool.** `pippin_status` (read-only): version, bound port,
  enabled modules, and per-permission TCC state. It is both the transport smoke
  test and genuinely the tool the user will want when something is not working.
- **S9 — Token model must not foreclose tiers.** Batch four adds multiple bearer
  tokens with per-token permission tiers (a remote token sees read-only tools
  only). Implement a single token now, but shape validation so that "N tokens,
  each mapped to a tier" is a natural extension — do not hardcode
  one-token-equals-full-access into the request path, the registry, or the config
  schema. This is the only forward-looking allowance batch one owes batch four,
  and it is cheap now and expensive later.

## Non-Requirements

- No app modules. Reminders and Mail are separate children.
- No escape hatch. Deferred to batch three.
- No notarization or distribution. Free-tier self-signing only, permanently (O2).
- No auto-update mechanism.
- No multi-token support, no permission tiers, no remote access. S9 only requires
  that the design not foreclose them.

## Acceptance Criteria

- [x] **AC1** `Scripts/package_app.sh` produces `Pippin.app`; `codesign -dv`
      reports the expected identity; `ls -R Pippin.app/Contents` shows the
      expected structure with `LSUIElement` and all usage descriptions present.
- [x] **AC2** Signing identity is byte-identical across three consecutive
      rebuild-and-repackage cycles, and a permission-dependent call keeps working
      with no fresh TCC prompt. (Feeds parent A1.)
- [x] **AC3** Claude Code connects over HTTP and lists exactly the enabled tools;
      Claude Code connects through `pippin-shim` and lists the same set.
      Verified 2026-09-04 under the post-rename names (`atmark-shim`,
      `atmark_status`); evidence in
      `research/step9-integration-verification.md` (§Claude Code verification).
- [x] **AC4** Two clients connected at once are served by one resident app
      process. A shim adds no shared or persistent state: each shim process holds
      only the temporary transport/session state scoped to its own stdio
      connection, and all of it disappears when that process exits. All shared
      business state and Apple-data handles remain owned exclusively by the one
      resident `Pippin.app` process. Verified by process inspection plus a config
      change that both clients observe. (Feeds parent A4.)
- [x] **AC5** A request with a missing or wrong bearer token is rejected 401. A
      request with a non-loopback `Origin` is rejected. A config with a
      non-loopback `bind` is refused at startup with a clear error.
- [x] **AC6** Disabling a module removes its tools from `tools/list` after one
      `list_changed` cycle, without restarting the app.
- [x] **AC7** `pippin_status` reports each permission's real state, including
      correctly reporting *not yet determined* versus *denied*.
- [x] **AC8** Shim failure paths are actionable: app not running and cannot be
      launched, `endpoint.json` missing, readiness timeout — each yields a
      distinct message, and none hangs.
- [x] **AC9** Unit tests cover confirm-token lifecycle (TTL, single-use, ID-set
      binding, session binding), registry gating, loopback-bind validation,
      AppleScript argument escaping, and the `tools/list` byte budget.
- [x] **AC10** GUI reviewed against HIG: standard controls, system materials, no
      custom chrome, correct menu bar behaviour for an `LSUIElement` app.
- [x] **AC11** Token validation is tier-ready: a token resolves to a capability
      set rather than to a boolean, and adding a second token with a read-only
      capability set requires no change to the request path or the registry.
      Demonstrated by a unit test that registers two tokens with different
      capability sets and asserts each sees a different tool list — even though
      only one token is provisioned in practice. (S9.)

## Constraints and Notes

- Parent Open Decisions O1–O3 are resolved (`addendum-2026-08-18.md` §1): the
  swift-sdk dependency is approved, signing uses the fixed self-signed keychain
  identity, and the batch-one `tools/list` budget is 6 KB.
- Lands before the Reminders and Mail children, which consume S7's primitives.
- Never validate permission-dependent behaviour via `swift run`; only the signed
  bundle is a supported run path.
- Relevant skills: `apple-skills:guide-macos-spm-packaging` (bundle assembly and
  stable dev signing templates), `apple-skills:hig` and
  `apple-skills:ios-liquid-glass` for the GUI, `apple-skills:swift-testing`,
  `apple-skills:guide-swift-concurrency` for the resident-actor design.
