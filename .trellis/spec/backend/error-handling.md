# Error Handling

## Domain Errors

Use `AtmarkError` from `Sources/AtmarkCore/AtmarkError.swift` for failures that a
tool caller or user can act on. Choose a stable `Code`, keep `detail` to the
failing field/backend/identifier name, and provide an imperative `hint`.
Argument values, tokens, and personal data must never enter `detail` or hints.

Examples of established mappings:

- `Config.validate` uses `.invalidArgument` with `http.bind` or `http.port`.
- `AppleScriptRunner.error(from:)` distinguishes Automation denial,
  app-not-running, and generic backend failures; `AppleScriptRunner.run` reports
  watchdog expiry as `.timeout`.
- `SQLiteReader` reports path, permission, schema, prepare, and step failures as
  `.backendUnavailable` rather than empty data.

At the MCP boundary, `ServerHost.call` maps expected dispatch failures through
`ServerHost.failure` to `CallTool.Result(isError: true)` with the compact
structured `{ error: { code, detail, hint } }` body. New tool handlers must do
the same for actionable `AtmarkError` values. Protocol/auth/session failures
remain HTTP/MCP errors. Do not throw a generic protocol error when the agent
needs the domain code and recovery hint.

Catch only where context can improve the result or cleanup is required.
`ServerRuntime.start` tears down partial state, records a user-facing failure,
and rethrows; `BackendRouter` preserves the first specific `AtmarkError`.

## Avoid

- Do not swallow permission, schema, partial-read, or transport failures.
- Do not expose raw arbitrary error text without bounding it; the AppleScript
  fallback caps stderr to 200 characters.
- Do not silently reset malformed persisted configuration. `Config.load` returns
  defaults only when the file is absent.
