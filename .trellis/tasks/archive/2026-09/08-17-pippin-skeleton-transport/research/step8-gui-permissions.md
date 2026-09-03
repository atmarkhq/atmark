# Step 8 — GUI and Permission Status Research

Date: 2026-08-23. Verified against the installed macOS 26.5 SDK headers and the
SwiftUI / EventKit interfaces shipped with Xcode 26.5. This is implementation
evidence, not a claim that private TCC storage is stable or supported.

## Permission semantics

### Reminders

Use `EKEventStore.authorizationStatus(for: .reminder)`. It is non-prompting and
distinguishes `.notDetermined`, `.restricted`, `.denied`, `.fullAccess`, and
`.writeOnly` (`.authorized` is a deprecated alias). Merely showing status must
not call `requestFullAccessToReminders`.

Wire states: `not_determined`, `restricted`, `denied`, `granted`, `write_only`.

For explicit onboarding only, the installed SDK imports
`EKEventStore.requestFullAccessToReminders()` as `async throws -> Bool`. Call it
only from a user-selected **Request Access…** action while the current state is
`not_determined`, then re-read `authorizationStatus`; never treat the returned
Boolean as the status source. A false result is an actionable refusal, not proof
that the state is any particular enum case.

### Mail Automation

Apple Events permission is per target. The public
`AEDeterminePermissionToAutomateTarget` API can query without prompting when
`askUserIfNeeded` is `false`, but its documented precondition is that the target
application is already running, and it may block. Run it away from the main
actor and never launch Mail merely to populate a status row.

Result mapping:

- `noErr` → `granted`
- `errAEEventNotPermitted` (`-1743`) → `denied`
- `errAEEventWouldRequireUserConsent` (`-1744`) → `not_determined`
- Mail not running / `procNotFound` → `unavailable`
- any other status → `unknown`

The product label must be **Mail Automation**, not global Automation.

For explicit onboarding, call the same function with `askUserIfNeeded: true`
only from a separate user-selected **Request Access…** action. The installed
Apple Events header says the target descriptor must refer to an already-running
application, the function is thread-safe, and a prompting call can block for an
arbitrary time; the request therefore runs explicitly off `MainActor`.
`noErr` is successful completion, `errAEEventNotPermitted` means access was not
granted, `procNotFound` means Mail stopped before the action ran,
`errAEEventWouldRequireUserConsent` means the prompting request did not complete,
and any other `OSStatus` is an actionable request failure. Every branch refreshes
the passive snapshot rather than deriving UI state from this result.

### Full Disk Access / Mail data

An ordinary macOS app has no supported public API that returns the global Full
Disk Access TCC state. Endpoint Security documents an effective check through
`es_new_client`, but that requires an entitlement and is not appropriate for
Pippin. Do not query the private TCC database.

Use a read-only effective-access probe of the existing `~/Library/Mail`
directory:

- directory can be enumerated/read → `granted`
- `EACCES` or `EPERM` → `denied`
- directory absent → `unavailable`
- any other failure → `unknown`

The GUI should say **Mail Data** and explain that it is effective access, while
the compact status key remains `full_disk_access` for the established product
vocabulary. This probe neither mutates data nor requests access.

There is no corresponding request API. The only honest onboarding control is
**Open Full Disk Access…**, accompanied by text that the user must add Pippin
manually. It opens the Full Disk Access pane and performs no probe beyond the
normal subsequent status refresh.

## System Settings routing

Use `NSWorkspace.shared.open` with the Privacy & Security extension URLs:

- Reminders: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders`
- Automation: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation`
- Full Disk Access: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`

`Privacy_AllFiles` is documented by an installed SDK header. The Reminders and
Automation route identifiers are present in the installed macOS 26 System
Settings resources but are not a public API contract; if opening a specific URL
fails, fall back to the general Privacy & Security pane. Use an ellipsis in the
button title because it opens another app.

The installed SDK also imports the macOS 10.15+
`NSWorkspace.open(_:configuration:)` and
`openApplication(at:configuration:)` completion APIs as async throwing Swift
methods. Use the former for privacy routes so failures can be surfaced, and the
latter for **Open Mail…** after resolving only bundle identifier
`com.apple.mail` with `urlForApplication(withBundleIdentifier:)`. The default
open configuration reuses an existing Mail process; set `activates = true` and
never use a name, arbitrary URL, shell, or deprecated launch API.

## SwiftUI/HIG wiring

- `MenuBarExtra` is available on macOS 13+; `.window` is a standard style suited
  to grouped live status and actions.
- `Settings { ... }`, `OpenSettingsAction`, and a replaced `.appSettings`
  command group provide native settings-window behaviour
  (`OpenSettingsAction` macOS 14+).
- Installed SwiftUI exposes `OpenSettingsAction.callAsFunction()` on macOS 14+,
  and AppKit exposes `NSApplication.activate()` on macOS 14+. For an
  `LSUIElement` app, use one `OpenSettingsAction`-backed semantic button in the
  menu and in `CommandGroup(replacing: .appSettings)`, call `NSApp.activate()`,
  then invoke the settings action so an existing scene is raised with Pippin active.
  `activateIgnoringOtherApps:` is deprecated in the installed AppKit header;
  window-title lookup is unnecessary.
- Use one `@MainActor @Observable` presentation model shared by both scenes.
  The actor-owned runtime remains the source of server state.
- Use `Form`, `Section`, `LabeledContent`, `Toggle`, `Button`, semantic styles,
  and system materials. Do not draw custom chrome or manually apply a glass
  effect to content; macOS 26 standard controls/surfaces adopt Liquid Glass.
- Refresh on appearance / explicit user action, not a tight polling loop. Status
  refresh must never cause a TCC prompt.

## Data flow and tests

1. The runtime exposes a live snapshot (running state, address, session count,
   config, permissions) and applies validated config changes.
2. A settings edit atomically saves `Config`, then calls
   `ServerHost.updateConfig`. The UI mirror advances only after both succeed.
3. `ServerHost` receives an injected permission provider. `pippin_status`
   awaits it and renders compact deterministic state strings. Unit tests use a
   fixed provider and never touch TCC.
4. Cover EventKit and OSStatus mapping as pure functions; provider edge cases;
   status schema/serialization; config-save rollback; and existing
   `tools/list_changed` propagation.
5. Manual verification must use the packaged, stably signed app and confirm
   menu-bar-only behaviour, native Settings/Command-comma, standard controls in
   light and dark appearance, and no permission prompt caused by opening or
   refreshing the UI.
