# Step 7 shim verification

- Date: 2026-08-23
- Scope: protocol relay, endpoint recovery, lifecycle, and Codex stdio smoke
- Claude Code: intentionally deferred to Step 9 because organization access is
  externally unavailable; this is not an implementation failure and AC3 remains
  open.

## Implementation evidence

- `PippinShim` is a testable library target; the `pippin-shim` executable owns
  only stderr diagnostics and the nonzero process exit.
- Endpoint discovery validates the 0600 file, loopback host, port, PID, and
  credential shape. Missing, malformed, stale, and unreachable states launch
  `io.github.is52hertz.pippin` through `/usr/bin/open -b` and use one bounded
  readiness deadline.
- The relay connects the SDK's raw `StdioTransport` and
  `HTTPClientTransport`. It preserves JSON-RPC payload bytes while converting
  newline, POST, SSE-event, and session-header framing. The first two inbound
  frames are sequenced for initialize/initialized ordering; later POSTs use a
  bounded queue so cancellation and unrelated calls can proceed concurrently.
- Normal stdin EOF gives already-accepted POSTs a two-second drain grace, cancels
  any remainder, sends best-effort authenticated DELETE for the in-memory
  session ID, then disconnects HTTP/SSE and stdio. The `/usr/bin/open` helper is
  also bounded, escalating from SIGTERM to SIGKILL if it fails to exit.
  Resident-process death and transport failures terminate with distinct,
  actionable diagnostics.
- The bearer token is captured only in memory by request modifiers and the
  best-effort terminator. SDK loggers are disabled. Diagnostics are credential-
  independent and have a regression test proving they cannot contain the test
  credential.

## Automated verification

- `swift build`: passed.
- `swift test`: passed, 172 tests in 22 suites.
- `git diff --check`: passed before review.
- Shim suites cover payload preservation, session capture/reuse/DELETE, JSON and
  202 responses, POST SSE priming suppression, multi-event SSE delivered one
  byte at a time (including a split UTF-8 scalar), bounded concurrent POSTs,
  the configured POST-concurrency ceiling, bounded EOF with a stuck POST,
  runtime resident death, endpoint missing/malformed/stale/non-private,
  launch and readiness failures, authentication failures, connection failures,
  and diagnostic token non-disclosure.
- The parity integration test starts the real Pippin HTTP listener and confirms
  an SDK client over direct HTTP and another SDK client through the shim receive
  identical `tools/list` results.

## Signed-bundle and Codex smoke

- `Scripts/package_app.sh` rebuilt the release bundle without creating or
  changing signing material. `codesign` reported bundle identifier
  `io.github.is52hertz.pippin` and authority `Pippin Local Signing`.
- Codex CLI was configured for this invocation only with the shim at
  `build/Pippin.app/Contents/MacOS/pippin-shim` as a stdio MCP server.
- Codex successfully invoked `pippin_status` through that shim and received
  version `0.1.0` plus the resident loopback endpoint. No endpoint credential was
  passed to Codex configuration, command arguments, stdout, or the evidence.
