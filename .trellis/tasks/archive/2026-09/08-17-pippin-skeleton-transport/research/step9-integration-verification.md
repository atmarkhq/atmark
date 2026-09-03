# Step 9 — Integration Verification

- Date: 2026-08-28
- Build: `9946b04` plus no production-code changes
- Scope: skeleton acceptance rerun, signed-bundle stability, live concurrency,
  Codex transport smoke, and explicit external blockers
- Secret handling: no endpoint token appears in commands, arguments, persistent
  client configuration, stdout, stderr, or this evidence

## Build and automated suites

The following passed:

- `swift build`
- `swift test` — 201 tests in 26 suites
- `swift build -c release`
- direct HTTP versus shim `tools/list` parity
- concurrent sessions and shared `ServerHost` state
- config-update `tools/list_changed` delivery to every affected session
- bearer and Origin validation, non-loopback bind refusal
- registry/write gating, token tiers, tool budget, confirm-token lifecycle
- shim endpoint recovery, framing, bounded failures, and credential-redaction tests

## Three stable-signing cycles

`Scripts/package_app.sh` ran three consecutive times. Every round passed strict
codesign verification and produced the same identity:

| Property | All three rounds |
|---|---|
| Authority | `Pippin Local Signing` |
| Certificate SHA-1 | `1AB7E0BC58C427092143FBADABA7F34CD607775D` |
| Certificate SHA-256 | `2662C98D777179098181467BED603722CE45007A79687561951E30983843578D` |
| Bundle identifier | `io.github.is52hertz.pippin` |
| Designated requirement | stable identifier plus the same certificate root |
| `LSUIElement` | `true` |

The final signed bundle launched as the only resident `Pippin` process. A passive
status call through its bundled shim still reported Reminders and effective Mail
Data access as granted. Mail Automation was unavailable because Mail was not
running; this is the designed non-prompting state, not permission loss.

On 2026-08-29, the user confirmed that the three cycles caused no fresh
Reminders, Automation, or Full Disk Access prompt. Together with the identical
certificate fingerprints and retained passive grants, this closes AC2.

## Live concurrent clients

Two separate bundled `pippin-shim` processes initialized and remained connected
at the same time. The resident signed app reported:

```text
LIVE_CLIENTS=2
DISTINCT_SHIM_PROCESSES=2
RESIDENT_PIPPIN_PROCESSES=1
TOOL_LISTS_EQUAL=true
TOOLS=pippin_status
SESSIONS_CLIENT_A=2
SESSIONS_CLIENT_B=2
MODULE_STATE_EQUAL=true
```

The automated SDK integration test independently changed the shared config and
confirmed both affected sessions received `notifications/tools/list_changed`.
Together these prove AC4 without adding a production test endpoint or mutating
the user's live config.

## Real Codex smoke

Codex CLI used invocation-only configuration and called `pippin_status` through
both supported transports:

| Transport | Result |
|---|---|
| bundled stdio shim | `PIPPIN_SHIM_SMOKE_OK 0.1.0` |
| direct Streamable HTTP | `PIPPIN_HTTP_SMOKE_OK 0.1.0` |

The shim required no client-visible credential. Direct HTTP used Codex's
`bearer_token_env_var` mechanism; only the environment-variable name entered
configuration, and the process was ephemeral.

## Claude Code blocker

Claude Code 2.1.250 is installed, but `claude auth status --json` reports
`loggedIn=false`, and `ANTHROPIC_API_KEY` is unset. Pippin did not start an
interactive login or persist MCP configuration. Consequently:

- protocol-level and Codex HTTP/shim evidence pass;
- Pippin has no observed transport defect;
- real Claude Code HTTP and shim smoke remain blocked by external credentials;
- AC3 and the first Step 9 item remain open.

## Acceptance status

| Criterion | Status | Evidence |
|---|---|---|
| AC1 package and signature | Pass | three packages plus bundle/signature inspection |
| AC2 TCC stability | Pass | identity and passive grants stable; user confirmed no fresh prompt |
| AC3 Claude Code HTTP + shim | Pass | 2026-09-04 live dual-transport test (see Claude Code verification below) |
| AC4 single-owner concurrency | Pass | two live shim clients, one app, shared-state transport test |
| AC5 validators | Pass | HTTP validator and live transport suites |
| AC6 structural module gating | Pass | synthetic catalogue plus list-changed integration |
| AC7 honest permission status | Pass | mapping tests and signed passive status call |
| AC8 bounded shim failures | Pass | endpoint/launch/readiness/auth/connection suites |
| AC9 core safety coverage | Pass | full unit suite |
| AC10 HIG | Pass | Step 8 signed-app review |
| AC11 tier-ready tokens | Pass | two-token capability test |

Step 9 closed 2026-09-04; AC3 is recorded as Pass in the table above.

## Update 2026-09-04 — Claude Code verification (AC3 closed)

The blocker resolved: the user logged Claude Code in on their own account. The
product now runs under its post-rename identity, so names differ from the PRD:
tool `atmark_status` is the PRD's `pippin_status`, and server name `atmark` is
the PRD's `pippin`. Atmark.app was packaged and launched fresh from the signed
bundle (identity unchanged, matching the repo-root notice: SHA-1
D636537074936D9266FA0FEA2175721C3E07B2A3); `endpoint.json` (mode 0600)
published port 51969.

Agent-side protocol pre-checks (no LLM tokens spent): `POST /mcp` without a
token returned 401; with the bearer token it returned 200 and issued an
`MCP-Session-Id`; a stdio handshake through the bundled shim listed exactly
`atmark_status`.

Live Claude Code test, reported by the user (2026-09-04): both registered
servers — `atmark-http` (direct Streamable HTTP) and `atmark-shim` (bundled
stdio shim) — exposed exactly one atmark tool, `atmark_status`, and its output
(version 0.1.0, port 51969, capabilities/modules/permissions snapshot) was
field-identical across the two transports, with no discrepancies. The user's
report is quoted in the session journal for this date.

Credential handling: the bearer token exists only in the project-local Claude
Code config (the user's `~/.claude-personal/.claude.json`, outside the repo)
and in `endpoint.json` (mode 0600, gitignored). It appears in no committed file,
argument, or log.
