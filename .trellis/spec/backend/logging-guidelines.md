# Logging Guidelines

Server-side operational logging uses `swift-log` `Logger` values injected with
stable labels such as `atmark.server` and `atmark.http`.

- Use `info` for lifecycle events: listener address, session opened, session
  expired.
- Use `warning` for recoverable degradation: configured-port fallback and a
  failed tool-list notification to one session.
- Attach small structured metadata when it identifies the operational unit;
  `ServerHost` uses `session`, `identity`, and `error` metadata.
- Log once at the layer that owns the operation. Lower-level code should return
  `AtmarkError`; the owning server/runtime decides whether an event is useful.

Never log bearer tokens, confirmation tokens, request bodies, tool argument
values, SQLite row contents, AppleScript output, or personal data. Avoid routine
per-request success logs and duplicate logs at each layer. User recovery belongs
in `AtmarkError.hint`, not only in a log line.
