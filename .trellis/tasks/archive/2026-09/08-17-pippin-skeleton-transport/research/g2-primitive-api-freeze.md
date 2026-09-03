# Gate G2 — Core Primitive API Freeze

Reviewed 2026-08-23, before module work starts. Both module children consume
these signatures; changing one afterwards means reworking two tasks at once.

## The frozen surface

All in `PippinCore`, which imports only Foundation, CryptoKit, and SQLite3 — no
SwiftUI, AppKit, NIO, or MCP. That boundary is what lets a module's safety
behaviour be tested without a transport, a GUI, or a TCC grant.

```swift
actor ConfirmTokenStore
  static let defaultTTL: TimeInterval           // 120s
  static let maximumItemsPerCall: Int           // 50
  static func hash(ids: [String]) -> String     // order-independent, SHA-256
  func mint(tool:sessionID:ids:) throws -> Minted   // .token, .expiresAt
  func consume(token:tool:sessionID:ids:) throws

struct MutationGate
  init(config:capabilities:)
  func check(_ capability: Capability, module: String) throws

actor AuditLog
  static func digest(_ arguments: [String: String]) -> String
  func record(tool:module:ids:outcome:error:arguments:)
  func entries() throws -> [Entry]

struct AppleScriptRunner
  static let defaultTimeout: Duration           // 15s
  func run(script:arguments:timeout:) async throws -> String

final class SQLiteReader
  init(path:) throws                            // read-only, immutable
  static func resolveVersionedPath(_:) throws -> String
  func probe(_ expected: [String: [String]]) -> Result<Void, PippinError>
  func query<T>(_ sql: String, parameters: [SQLiteValue], map: (Row) -> T) throws -> [T]

enum BackendRouter
  static func route<Value>(_ backends: [Backend<Value>], capability: String)
      async throws -> RoutedResult<Value>       // .value, .backend, .degraded, .reason

struct ToolContext
  let sessionID, capabilities, config
  let confirmTokens, audit, appleScript
  var gate: MutationGate                        // derived, never stored
  func confirmDestructive(tool:module:ids:confirmToken:preview:perform:) async throws -> JSONValue
```

## What the review changed

**`ToolContext` did not exist, and had to.** The six primitives were individually
complete and collectively unusable: nothing carried `sessionID` into a module's
tool handler, and confirm-token session binding (parent criterion A2) is defined
in terms of it. Both module children would have invented their own arrangement,
and the two would not have matched. Catching that is what this gate is for.

It also absorbed the two-phase delete protocol itself. Leaving each module to
call `mint` and `consume` correctly would mean each module separately remembering
to check expiry, single use, tool identity, session identity, and item-set
equality, and to audit all three outcomes. `confirmDestructive` makes the
guarantees hold by construction: gate first, preview performs nothing, token
burned before `perform` runs, every arm audited.

## What the tests establish

151 tests, 18 suites. The ones that carry the design's weight:

| Property | How it is shown |
|---|---|
| AppleScript injection is inert | Four payloads that would be code if interpolated, run through real `osascript`, come back as text; the `do shell script` payload creates no file |
| AppleScript timeouts actually fire | A 10-second script under a 600 ms timeout returns in ~0.6 s as `timeout` |
| SQL injection is inert | Three payloads bound as parameters match nothing and leave the table intact |
| A failed schema probe never returns zero rows | Probe against a renamed column fails with the column named and the word "fallback" |
| Routing never returns silently empty | Every backend failing throws the first real error; no backends at all throws |
| Confirm tokens cannot be replayed, moved, or re-aimed | Single use, TTL, tool binding, session binding, item-set binding, order independence |
| Deletes cannot be unbounded | Empty list, over-cap list, and duplicate ids all refused |
| The audit trail holds no user data | Argument values are digested; the raw file does not contain the note body |

## Bugs this step surfaced

1. **The AppleScript timeout did not work.** `readDataToEndOfFile()` was called
   before the watchdog, and it blocks until the child closes the pipe — so the
   watchdog could only fire after the thing it was watching had already finished.
   A hung Apple Event would have wedged the resident server for every client,
   which is the precise failure the timeout exists to prevent. Pipes are now
   drained on their own tasks.
2. **The timeout outcome was decided by a race.** Terminating the process makes
   the wait task finish too, so whichever task returned first said nothing about
   *why*. Replaced with a flag set before the signal.
3. **`sqlite3_step` errors were swallowed.** `while step == SQLITE_ROW` treats a
   read-only violation, a corrupt page, or a vanished file as "finished",
   silently truncating results — the exact shape of failure criterion A7
   forbids. The terminal code is now required to be `SQLITE_DONE`.
4. **Output trimming discarded real data.** `trimmingCharacters(.whitespacesAndNewlines)`
   would alter a subject or note that legitimately begins or ends with a space.
   Only the trailing newline `osascript` appends is removed now.

## Notes for the module children

- Take a `ToolContext`; do not construct primitives yourselves.
- Destructive verbs go through `context.confirmDestructive`. Do not call `mint`
  or `consume` directly — the guarantees live in the wrapper.
- `AppleScriptRunner.run(script:arguments:)`: script text is authored in the
  repository, caller values go in `arguments`. There is no overload that takes
  an assembled string, and there should not be one.
- `SQLiteReader.query` likewise: `sql` is ours, values are `parameters`.
- Probe at startup and route with a fallback. A backend that cannot answer must
  produce an error with a hint, never an empty list.

**G2 passed.**
