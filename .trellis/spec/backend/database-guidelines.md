# Database Guidelines

Atmark does not own an ORM or migration system. `SQLiteReader` provides the
read-only infrastructure for best-effort access to private stores owned by other
macOS apps; no production module uses it yet.

## Scenario: Private SQLite Read Backend

### 1. Scope / Trigger

Apply this contract whenever a module reads a private database owned and
modified by another macOS application, beginning with Mail's Envelope Index.

### 2. Signatures

- `SQLiteReader.resolveVersionedPath(_:) throws -> String` resolves one `*`
  version component at runtime.
- `SQLiteReader.init(path:) throws` opens the database read-only.
- `SQLiteReader.probe(_:) -> Result<Void, AtmarkError>` verifies required tables
  and columns before the backend is considered available.
- `SQLiteReader.query(_:parameters:map:) throws -> [T]` accepts
  repository-authored SQL and bound `[SQLiteValue]` parameters.

### 3. Contracts

- Open the ordinary path with
  `SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE`, then require
  `sqlite3_db_readonly(handle, "main") == 1`. Configure a 250 ms
  `sqlite3_busy_timeout`. Never assert `immutable=1` or use URI mode for a live
  store owned and changed by another app.
- Validate change visibility and WAL behavior against the owning application's
  writes. A long-lived reader must observe a later committed WAL change on its
  next statement.
- Resolve versioned private-store paths at runtime with
  `SQLiteReader.resolveVersionedPath`; never hard-code a Mail `V10`-style
  version directory.
- Probe required tables and columns with `SQLiteReader.probe` before trusting a
  private schema. A failed probe disables or degrades that backend.
- Keep SQL repository-authored. Pass all caller values as `[SQLiteValue]` to
  `SQLiteReader.query`; identifiers used by PRAGMA must be trusted constants and
  passed through `quoteIdentifier`.
- Serialize access through the reader's private queue and always finalize the
  prepared statement. Treat any terminal step other than `SQLITE_DONE` as an
  error, not a short or empty result.

### 4. Validation and Error Matrix

| Condition | Required result |
|---|---|
| Mail directory cannot be listed/read | `backend_unavailable` with Full Disk Access hint |
| No matching version directory | `backend_unavailable`; never hard-code a fallback version |
| Required table or column missing | disable/degrade SQLite backend with recorded reason |
| Read-only verification or busy-timeout setup fails | `backend_unavailable`; do not query |
| Prepare/step returns primary or extended `BUSY` / `LOCKED` | `backend_unavailable` with retry/fallback guidance |
| Other prepare, bind, or terminal step failure | explicit schema/query error; never return fabricated zero rows |
| SQLite unavailable but fallback succeeds | response marked `degraded` with reason |
| All backends unavailable | throw actionable `AtmarkError` |

Missing Full Disk Access, a moved path, a changed schema, and an incomplete query
must become actionable `AtmarkError` values. `BackendRouter.route` may fall back
to another backend, but it reports `degraded` and `reason`; if all backends fail,
it throws rather than returning a fabricated empty answer.

### 5. Good / Base / Bad Cases

- Good: dynamically resolve the active `V*` directory, open read-only, pass the
  schema probe, and bind every caller value.
- Base: a probe fails after a macOS update and AppleScript serves the request
  with an explicit degraded marker.
- Bad: hard-code `V10`, interpolate search text, use `immutable=1` against a
  live-changing database, or translate a backend failure into `[]`.

### 6. Tests Required

- `Tests/AtmarkCoreTests/SQLiteReaderTests.swift`: read-only opening, actual WAL
  mode plus later-commit visibility on one reader, rollback-journal contention
  returning inside the 750 ms test bound, version resolution, bound injection
  payloads, schema mismatch, missing path, and terminal query failure.
- `Tests/AtmarkCoreTests/BackendRouterTests.swift`: primary success, degraded
  fallback, and all-backends-failed behavior.
- Each concrete module adds an integration test while the owning app is running,
  including WAL/change visibility and the permission-denied path.

### 7. Wrong vs Correct

Wrong: use `file:...?immutable=1` to bypass locks on a live store, or treat a
`BUSY` returned during prepare as schema drift.

Correct: open the ordinary path read-only with a bounded busy timeout, resolve
and probe dynamically, query with bindings, and either return real rows,
explicitly degrade to a known fallback, or fail actionably.

## Avoid

- No writes, migrations, schema repair, or write-intent locks against another
  app's DB.
- No `immutable=1`, URI construction, shared cache, or unbounded busy handler for
  a live private store.
- No SQL interpolation for values and no caller-controlled table names.
- No conversion of permission/schema failures into zero rows.
