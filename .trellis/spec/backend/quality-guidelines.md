# Backend Quality Guidelines

Swift 6.2 strict concurrency and macOS 26 are declared in `Package.swift`.
Prefer `Sendable` values and actors for shared mutable state: `ConfirmTokenStore`,
`ServerHost`, `HTTPListener`, and `ServerRuntime` are current examples. Any
`@unchecked Sendable` or `nonisolated(unsafe)` must stay narrow and explain the
external synchronization or event-loop ownership that makes it valid.

Tests are required for behavior changes. Place them in the matching target
directory and cover both success and the safety failure path. In particular,
verify input validation, authorization/capability filtering, token expiry and
single use, SQLite binding/probe failures, backend fallback, session lifecycle,
and cleanup after startup failure when affected.

Use the smallest relevant command while iterating, then the full suite:

```bash
swift test --filter AtmarkCoreTests
swift test --filter AtmarkServerTests
swift test --filter AtmarkAppTests
swift test --filter AtmarkShimTests
swift test
swift build
```

There is no separate lint command configured in `Package.swift`; do not claim
lint coverage. Review the target import graph when moving code across layers.
