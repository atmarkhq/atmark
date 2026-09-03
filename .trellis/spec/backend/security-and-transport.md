# Security and Transport

## Scenario: Local MCP Request and Destructive Tool Call

### 1. Scope / Trigger

The service is local but still handles untrusted MCP requests and tool arguments.
Preserve every independent guard; do not rely on an earlier layer having run.

This contract applies when changing `HTTPListener`, `ServerHost`, `ToolRegistry`,
`ToolContext`, bearer capabilities, session handling, or a destructive tool.

### 2. Signatures

- `HTTPListener.start() async throws -> Int` binds and returns the actual port.
- `ServerHost.handle(_ request: HTTPRequest) async -> HTTPResponse` owns
  authentication and session routing.
- `ToolRegistry.tools(config:capabilities:) -> [Tool]` derives the visible tool
  surface by absence.
- `ToolContext.confirmDestructive(tool:module:ids:confirmToken:preview:perform:)`
  owns both arms of the delete protocol.
- `ToolContext.performMutation(tool:module:ids:arguments:perform:)` owns durable
  intent, execution, outcome, and degraded-success sequencing for ordinary
  writes.
- `AppleScriptRunner.run(script:arguments:targetBundleID:queueTimeout:
  operationTimeout:maximumOutputBytes:)` owns per-App serialization and bounded
  subprocess execution.

### 3. Contracts

- `Config.validate` and `HTTPListener.start` both enforce literal IPv4/IPv6
  loopback with `Config.isLoopback`; hostnames and non-loopback binds are invalid.
- `ServerHost.handle` authenticates the bearer token before session lookup.
  `validationPipeline` then applies bearer, Origin, Accept, Content-Type,
  protocol-version, and session validators in that order.
- A session remains bound to the token and capabilities that opened it.
  `ToolRegistry.tools` filters by capability, module enablement, and write gate;
  `ServerHost.call` re-checks visibility to reject stale cached tool lists.
- `ConfirmTokenStore` binds destructive confirmation to tool, session, exact ID
  set, expiry, and single use. `ToolContext.confirmDestructive` centralizes the
  preview/consume/audit sequence and caps explicit unique IDs at 50.
- `AppleScriptRunner` accepts repository-authored script text only. Untrusted
  values travel through `on run argv` process arguments. Calls serialize by
  target bundle ID while unrelated targets may overlap; queue wait, operation
  time, stdout, and stderr are all bounded.
- AppleScript launches with Darwin `posix_spawn`, atomically creating a new
  process group with `POSIX_SPAWN_SETPGROUP` and pgroup zero. Timeout,
  cancellation, output overflow, or a leader that exits before descendants
  triggers group TERM, a 200 ms grace period, group KILL, direct-child reap, and
  closure of every pipe descriptor. Never use `Process.run()` followed by
  `setpgid`; that sequence races with exec.
- `AuditLog.record` is best-effort only for previews/refusals. Every real write
  uses `ToolContext.performMutation`: gate (plus destructive token consumption),
  synchronized mode-0600 intent with UUID, perform, then synchronized outcome.
  Intent failure returns `backend_unavailable` / `audit_log` and performs
  nothing. Outcome failure after success returns the real result plus
  `audit_degraded: true` and the fixed no-retry hint, and blocks later mutations
  until their own synchronized intent recovers journal health.
- `SQLiteReader.query` binds values and accepts only repository-authored SQL.

The published endpoint is private mode `0600`. Bearer and confirmation tokens
may exist in memory where their transport protocol requires them, but they must
never appear in logs, errors, status tools, UI, or audit records.

### 4. Validation and Error Matrix

| Condition | Required result |
|---|---|
| Missing or unknown bearer token | HTTP `401` before routing |
| Non-loopback `Origin` | HTTP `403` |
| Non-loopback bind configuration | startup/configuration error |
| Unknown or closed MCP session | protocol-appropriate not-found response |
| Tool hidden by module/capability gates | absent from `tools/list`; stale call rejected |
| Destructive call without token | no mutation; preview plus `confirmation_required` |
| Expired, replayed, wrong-session, wrong-tool, or changed-ID token | `confirmation_invalid`; no mutation |
| AppleScript waits past its queue budget | `timeout` / `applescript_queue`; process is not spawned |
| AppleScript exceeds operation budget | terminate/reap whole group; `timeout` / `applescript` |
| AppleScript stdout or stderr exceeds its cap | terminate/reap whole group; `backend_unavailable` / `applescript_output` |
| Caller cancels queued or running AppleScript | remove waiter or terminate/reap whole group; propagate cancellation |
| Required mutation intent cannot append or synchronize | `backend_unavailable` / `audit_log`; `perform` is not called |
| Mutation succeeds but outcome cannot append or synchronize | return actual result with `audit_degraded` and no-retry hint; latch later mutations |

### 5. Good / Base / Bad Cases

- Good: a full-capability local token sees enabled write tools; a matching
  single-use confirmation token authorizes exactly the previewed IDs.
- Base: a read-only token sees only read tools, and a module with writes off
  contributes no mutating tools.
- Bad: a client reuses another session's token, changes the ID set after preview,
  or calls a tool cached before it was disabled; every case must fail closed.
- Good: two Mail scripts serialize, a Notes script may overlap, and cancelling a
  wedged Mail script removes descendants that ignore TERM.
- Base: a preview/refusal audit write fails but no Apple data mutation occurs, so
  the caller still receives the intended preview/refusal response.
- Bad: a confirmed delete executes after its required intent failed, or returns
  a generic error after the delete succeeded but outcome logging failed; both
  can cause untraceable or duplicate mutation.

### 6. Tests Required

- `Tests/AtmarkServerTests/ServerHostTests.swift`: authentication, Origin,
  session binding, stale calls, concurrent clients, and DELETE lifecycle.
- `Tests/AtmarkServerTests/ToolRegistryTests.swift`: module/write/capability
  visibility and deterministic ordering.
- `Tests/AtmarkCoreTests/ConfirmTokenTests.swift` and
  `ToolContextTests.swift`: TTL, single use, exact ID set, tool/session binding,
  no-mutation preview, intent-before-perform, degraded success, health
  block/recovery, and audit outcomes.
- `Tests/AtmarkCoreTests/AppleScriptRunnerTests.swift`: same-target serialization,
  cross-target overlap, queued/running cancellation, both timeouts, bounded
  stdout/stderr, injection payloads, spawn failure, leader-exit descendant
  cleanup, and no surviving processes without invoking TCC.
- `Tests/AtmarkCoreTests/SafetyPrimitivesTests.swift`: intent/outcome UUID
  correlation, append/sync and every rotation failure point, tail isolation,
  modes 0700/0600, unhealthy-latch semantics, and one-generation rotation.
- Re-run `ToolSurfaceBudgetTests` whenever production tools change.

### 7. Wrong vs Correct

Wrong: expose every tool and return `writes_disabled` only after the agent calls
it, accept `confirm: true` as deletion authorization, kill only the immediate
`osascript` PID, or silently swallow a required mutation-intent write failure.

Correct: remove unavailable tools in `ToolRegistry`, re-check visibility in
`ServerHost.call`, and route every destructive operation through
`ToolContext.confirmDestructive`. Route all writes through
`ToolContext.performMutation`, and make the AppleScript process group—not only
its leader—the unit of cleanup.

## Adapter Boundary

`HTTPListener` is an adapter: exact-path matching, repeated-header joining, SSE
chunk flushing, and NIO event-loop writes stay there; authentication, session
routing, and tool decisions stay in `ServerHost`. HTTP serving must not hop onto
the SwiftUI main actor.

## Avoid

- Never widen the listener to `0.0.0.0`, a hostname, or LAN interfaces.
- Never interpolate caller input into AppleScript or SQL.
- Never authorize a destructive action by a Boolean flag or reusable token.
- Never expose a disabled tool and rely only on execution-time refusal.
- Never publish endpoint metadata before the listener is accepting connections.
- Never capture unbounded process output or signal a PID/process group not
  created for the current request.
- Never call a local JSONL journal tamper-proof or compliance-grade, and never
  log bearer/confirmation tokens, raw arguments, Apple data, or script output.
