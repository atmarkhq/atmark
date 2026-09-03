# Backend Specifications

These rules cover the SwiftPM service layers in `Sources/AtmarkCore`,
`Sources/AtmarkModules`, and `Sources/AtmarkServer`.

## Pre-Development Checklist

- Read [Directory Structure](./directory-structure.md) before placing code.
- Read [Security and Transport](./security-and-transport.md) for any request,
  session, tool, AppleScript, SQLite, token, or listener change.
- Read [Database Guidelines](./database-guidelines.md) when accessing SQLite or
  another application's data.
- Read [Error Handling](./error-handling.md) and [Logging](./logging-guidelines.md)
  when adding a failure path or operational event.
- Read [Quality](./quality-guidelines.md) before writing or running tests.

## Non-Negotiable Boundary

`AtmarkCore` must remain independent of MCP, SwiftNIO, SwiftUI, and AppKit.
`Package.swift` expresses this in the target graph; transport adaptation belongs
in `AtmarkServer`, while application lifecycle and UI belong in `AtmarkApp`.
