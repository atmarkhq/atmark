# State Management

There is no third-party state library. State flows from actor-owned runtime
objects into a shared presentation model and then into SwiftUI views.

- `ServerRuntime` is the source of truth for process lifecycle and server
  ownership. Its `AppRuntimeState` and `AppRuntimeSnapshot` are `Sendable`; the
  runtime is accessed through the `ServerRuntimeServing` protocol for tests and
  preview substitutes.
- `ServerHost` remains the source of server/session/config state. The app consumes
  snapshots instead of mirroring transport internals.
- Apply settings in the existing order in `ServerRuntime.updateConfig`: validate,
  atomically save through `Config.save`, update the resident host, then return a
  fresh snapshot. A caller must not advance its UI mirror on failure.
- On startup failure, tear down listener/host/endpoint state before publishing
  `.failed`; on stop, remove endpoint metadata and clear owned server objects.
- `AtmarkApp` obtains the shared model from `AppDelegate` and supplies the same
  instance to menu-bar and Settings surfaces.

Avoid duplicate sources of truth in individual views, direct config-file writes
from controls, detached lifecycle tasks without an owner, and optimistic UI
state that survives a failed runtime update.
