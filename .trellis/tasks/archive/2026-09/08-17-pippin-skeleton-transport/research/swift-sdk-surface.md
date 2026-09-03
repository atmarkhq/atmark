# Step 0 — swift-sdk Surface, Verified Against Source

Method: shallow-cloned `modelcontextprotocol/swift-sdk` at tag `0.12.1` (latest)
and read the source, then compiled a throwaway probe against it. Everything below
is read off the real package, not from documentation.

Probe: `Package.swift` (tools 6.2, `.macOS(.v26)`, Swift 6 language mode) plus one
`main.swift` exercising every API this task depends on. **`swift build` succeeds**;
the only diagnostic is one deprecation, noted below. Running it prints `406` from
the validation pipeline, which is the correct rejection for a probe request that
omits the `Accept` header — proving custom validator composition works.

## Confirmed API

| Item | Verified shape |
|---|---|
| `Server.init` | `(name:version:title:instructions:capabilities:configuration:)` |
| `Server.start` | `(transport: any Transport, initializeHook:)` |
| `withMethodHandler` | `<M: Method>(_ type: M.Type, handler: @Sendable (M.Parameters) async throws -> M.Result) -> Self`, `@discardableResult` |
| `ListTools` | `Parameters(cursor: String?)`, `Result(tools:nextCursor:_meta:)` — cursor pagination is native |
| `CallTool` | `Parameters(name:arguments: [String: Value]?:_meta:)`, `Result(content:structuredContent:isError:_meta:)`; a `structuredContent:` overload takes any `Codable` |
| `Tool` | `init(name:title:description:inputSchema:annotations:outputSchema:icons:_meta:)` — `outputSchema` present |
| `Tool.Annotations` | `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, all `Bool?` |
| list_changed | `ToolListChangedNotification` (`notifications/tools/list_changed`), sent via `server.notify(_:)`; declare `capabilities: .init(tools: .init(listChanged: true))` |
| `StdioTransport` | `public actor`, present, no arguments required |
| Validators | `HTTPRequestValidator` protocol; ships `OriginValidator.localhost(port:)`, `AcceptHeaderValidator`, `ContentTypeValidator`, `ProtocolVersionValidator`, `SessionValidator`; composed by `StandardValidationPipeline(validators:)` |

Two build facts for step 1:

- **`.macOS(.v26)` requires `// swift-tools-version:6.2`.** It is unavailable at
  6.1 (`'v26' was introduced in PackageDescription 6.2`). Local Swift is 6.3.2, so
  this only constrains the manifest line.
- `Tool.Content.text("…")` is deprecated; use `.text(text:annotations:_meta:)`.

## THE STOP CONDITION — RESOLVED, no design change required

`implement.md` step 0 said: if per-request session identity is not exposed, stop
and revise the confirm-token design before writing any tool. **It is exposed, two
ways over.**

1. `Server.currentHandlerContext` is an `@TaskLocal` of type `HandlerContext?`,
   set by the SDK around every dispatch. Its `httpContext: HTTPRequest?` is the
   originating HTTP request — headers, auth, path, body — available inside a
   handler without changing the `withMethodHandler` signature. Supplied by any
   transport conforming to `HTTPContextProviding`; both HTTP server transports do.
   So a handler can read `Mcp-Session-Id` *and* the bearer token of the call it is
   serving.
2. More directly still: under the SDK's own multi-session pattern (below) each
   `Server` instance is constructed for exactly one session, so session identity
   can simply be captured at construction.

Parent criterion A2 (confirm tokens bound to the requesting session) stands as
written. One implementation note: task-locals are not inherited by
`Task.detached`, so capture `Server.currentHandlerContext` before detaching.

## FINDING 1 — The SDK ships no HTTP listener

`StatefulHTTPServerTransport.init` is
`(sessionIDGenerator:validationPipeline:retryInterval:logger:)`. **There is no
`port` and no `host`.** The type is a framework-agnostic request handler:

```swift
// In your HTTP framework handler:
let response = await transport.handleRequest(httpRequest)   // HTTPRequest -> HTTPResponse
```

`HTTPResponse` is an enum with an `.stream(AsyncThrowingStream<Data, Error>)` case
for SSE that the adapter must pipe to the client itself.

This contradicts parent `design.md` §2, which wrote
`StatefulHTTPServerTransport(port:, host: "127.0.0.1")`. That signature does not
exist. **We must supply the listener.** The SDK's own conformance server does
exactly that, in `Sources/MCPConformance/Server/HTTPApp.swift`, using swift-nio
(`NIOCore` / `NIOPosix` / `NIOHTTP1`) as a dependency of that target only — the
`MCP` library target itself never depends on NIO.

Relevant to the choice: resolving swift-sdk already pulls `swift-nio 2.101.3`
(plus `swift-atomics`, `swift-collections`) into `Package.resolved`, because
swift-sdk's manifest declares it for those executable targets. Declaring NIO
ourselves would therefore add a manifest line and a build, not a new package to
the resolution graph. This is recorded as open decision **O4** in the parent
`prd.md`; it is a dependency question and belongs to the user (C5).

## FINDING 2 — One session per transport, so N Server instances per process

`StatefulHTTPServerTransport` holds `private var sessionID: String?` and rejects a
second `initialize` with *"Session already initialized"*. One transport instance
serves exactly one MCP session for its lifetime.

The SDK's supported pattern for many clients (`HTTPApp.swift`):

```swift
typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server
private var sessions: [String: SessionContext]   // sessionID -> (server, transport, timestamps)
```

- No `Mcp-Session-Id` header + `initialize` → mint a session ID, build a transport
  with a `FixedSessionIDGenerator`, call the factory for a fresh `Server`,
  `start(transport:)`, store it.
- Subsequent requests route to the matching transport by header.
- A sweep closes sessions past a timeout; DELETE closes one.

**Impact on parent design.** "One resident instance" is still correct and still
required — but at the level of the *process*, not the `Server` object. The
sentence has to be re-scoped: one resident process, one shared state core, and one
`Server`+transport pair per connected client.

This is a correction of altitude, not of direction: the reason we wanted one
instance (a single `EKEventStore`, one confirm-token store, one audit log, one
timeout regime) is served by putting that state in a process-level actor injected
into every per-session `Server`. It also makes A2 mechanical — the session key is
the session table's key.

What must move out of per-session scope and into the shared core:
`EKEventStore` / module backends, `ConfirmTokenStore`, `AuditLog`, `MutationGate`,
`Config`, `TokenStore`. What stays per-session: the `Server`, its transport, its
registered handlers, and the resolved capability set for that client's token.
