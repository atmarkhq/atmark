# Research: swift-sdk 0.12.1 shim transport surface

- Query: Verify the real `modelcontextprotocol/swift-sdk` tag `0.12.1` before Step 7, including HTTP client, stdio, typed Client/Server proxy limits, the smallest Pippin shim, tests, protocol edges, dependency sufficiency, and security constraints.
- Scope: mixed (the resolved local source checkout plus official upstream tag/release source)
- Date: 2026-08-23

## Findings

### Executive conclusion

The repository is actually resolved to `swift-sdk` **0.12.1**, full revision
`a0ae212ebf6eab5f754c3129608bc5557637e605`. The local checkout metadata contains
that same revision, and GitHub's official 0.12.1 release identifies commit
`a0ae212`. This research therefore cites the source that the project builds, not
`main` and not documentation examples.

The smallest viable Pippin shim is a **transport-to-transport Data relay** using
`StdioTransport` and `HTTPClientTransport` directly. Do not put SDK `Client` or
`Server` between them: those actors consume lifecycle messages and require typed
method/notification registration, so they cannot be a transparent wildcard
proxy.

The existing dependency set is sufficient. `swift-sdk` supplies newline stdio
framing, HTTP POSTs, session-header capture, JSON response delivery, SSE parsing,
standalone GET SSE, and reconnect state. Foundation supplies endpoint decoding,
`URLSession` readiness and DELETE requests, bounded timing, file/process APIs,
and launching `/usr/bin/open`. Pippin still has to implement orchestration,
startup/readiness, concurrent relay coordination, normal-shutdown DELETE, and
actionable stderr-only failures. No new package is needed or recommended.

The design statement "the shim holds no state" cannot be literal: the SDK HTTP
transport necessarily holds an ephemeral `sessionID`, `lastEventID`, retry
interval, streams, and tasks, while stdio holds a partial-line buffer. The
security-preserving interpretation is: **no persistent or domain/TCC state; only
per-process framing, lifecycle, and session state**.

### Source identity and resolved versions

- Project `Package.resolved:50-56` pins `swift-sdk` 0.12.1 at full revision
  `a0ae212ebf6eab5f754c3129608bc5557637e605`.
- `.build/checkouts/swift-sdk/.git` contains exactly that full revision, so the
  files under that checkout are the resolved source tree.
- The official [GitHub 0.12.1 release](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1)
  maps the tag to short commit `a0ae212`.
- `Package.swift:18` pins the package with `exact: "0.12.1"`.
- On macOS, the SDK's `MCP` product directly links `EventSource`
  (`.build/checkouts/swift-sdk/Package.swift:36-44`). The project resolves that
  transitive dependency to EventSource 1.5.1 (`Package.resolved:4-11`). Thus SSE
  parsing does not require a new direct dependency.
- `Version.latest` is `2025-11-25`; supported versions are `2025-11-25`,
  `2025-06-18`, `2025-03-26`, and `2024-11-05`
  (`.build/checkouts/swift-sdk/Sources/MCP/Base/Versioning.swift:8-18`).

### 1. `HTTPClientTransport`: exact surface and behavior

#### Public transport contract

All built-in transports expose raw JSON-RPC payloads through the same public
protocol (`.../Base/Transport.swift:5-20`):

```swift
public protocol Transport: Actor {
    var logger: Logger { get }
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}
```

`HTTPClientTransport` is a public actor conforming to that protocol
(`HTTPClientTransport.swift:56`). Its public initializer is
(`HTTPClientTransport.swift:110-130`):

```swift
public init(
    endpoint: URL,
    configuration: URLSessionConfiguration = .default,
    streaming: Bool = true,
    sseInitializationTimeout: TimeInterval = 10,
    protocolVersion: String = Version.latest,
    authorizer: (any HTTPClientAuthorizer)? = nil,
    requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
    logger: Logger? = nil
)
```

Its relevant public state is `endpoint: URL`,
`public private(set) var sessionID: String?`, `protocolVersion: String?`, and
`sseInitializationTimeout: TimeInterval` (`HTTPClientTransport.swift:56-80`).

#### `connect()` and `disconnect()`

- `connect()` is idempotent, marks the actor connected, prepares a session-ID
  signal, and starts the GET-SSE task when `streaming == true`
  (`HTTPClientTransport.swift:183-195`). **It performs no network request and is
  not a readiness probe.**
- `disconnect()` cancels the SSE task, calls `URLSession.invalidateAndCancel()`,
  finishes the receive stream, and releases the session-ID waiter
  (`HTTPClientTransport.swift:197-214`). It does not send HTTP DELETE, does not
  clear `sessionID`, and makes the instance effectively one-shot because the
  URLSession and message continuation are finished.
- With `logger: nil`, the actor creates a no-op logger
  (`HTTPClientTransport.swift:155-160`). This is the right shim default.

#### Authentication and headers

- Every POST is built with raw `data` as `httpBody`, `Content-Type:
  application/json`, `Accept: application/json, text/event-stream`, the current
  protocol version, and (once known) `MCP-Session-Id`
  (`HTTPClientTransport.swift:244-260`).
- Every standalone GET has `Accept: text/event-stream`, `Cache-Control:
  no-cache`, protocol version, session ID, and optional `Last-Event-ID`
  (`HTTPClientTransport.swift:587-607`).
- There are two auth mechanisms: a typed OAuth `authorizer`, or arbitrary
  per-request customization through `requestModifier`. The modifier is applied
  after built-in headers on **both POST and GET**
  (`HTTPClientTransport.swift:262-266`, `609-613`). For Pippin's fixed local
  bearer token, `requestModifier` is the smaller and correct surface; OAuth
  discovery is unnecessary.
- Use `setValue("Bearer …", forHTTPHeaderField: "Authorization")` in the
  modifier, capture the token only in memory, use the no-op logger, and never
  print/dump the request. Upstream's request-modifier test verifies the header
  path (`HTTPClientTransportTests.swift:1253-1294`).
- The SDK logs session IDs when a non-no-op logger is supplied, but the reviewed
  transport source does not log Authorization values or request bodies. Pippin
  should still keep the logger disabled so later SDK logging changes cannot put
  sensitive transport context on stderr.

#### `MCP-Session-Id` lifecycle

1. `sessionID` starts `nil` (`HTTPClientTransport.swift:61-63`).
2. A response header on either POST or GET replaces the stored value. The first
   transition from nil wakes the standalone SSE task
   (`HTTPClientTransport.swift:315-321`, `347-353`, `631-637`). The code does not
   reject a later server-supplied replacement value.
3. Subsequent POSTs and GETs carry the stored ID
   (`HTTPClientTransport.swift:258-260`, `598-600`).
4. HTTP 404 clears a non-nil session ID and throws `Session expired`; a 404
   before a session exists throws `Endpoint not found`
   (`HTTPClientTransport.swift:400-406`).
5. Normal `disconnect()` neither sends DELETE nor resets the property.

The upstream session tests cover initial capture, reuse, and 404 clearing
(`HTTPClientTransportTests.swift:217-298`, `921-978`).

#### POST response handling

- On macOS, `send(_:)` calls `URLSession.bytes(for:)`, then awaits the complete
  response processing before returning (`HTTPClientTransport.swift:268-276`).
  For a POST SSE response, that means `send` remains suspended until that SSE
  stream closes.
- Any `2xx` status is accepted before body-type dispatch
  (`HTTPClientTransport.swift:380-383`). Therefore a notification/client-response
  POST receiving `202 Accepted` with no body is successful. With no Content-Type,
  it only takes the "unexpected content type" warning path and yields no frame
  (`HTTPClientTransport.swift:356-376`). With the no-op logger this is silent.
- `application/json` is fully buffered and yielded as one raw `Data` frame
  (`HTTPClientTransport.swift:367-373`).
- `text/event-stream` is parsed event by event. Every non-empty SSE `data` field
  is UTF-8 encoded and yielded as one `Data` frame; priming events with empty
  data are deliberately not yielded (`HTTPClientTransport.swift:644-684`). IDs
  and `retry:` values update reconnection state.
- Unexpected successful Content-Type values are discarded, not exposed
  (`HTTPClientTransport.swift:374-376`). Pippin's server returns SSE for requests
  and no body for 202, so its current response shapes are covered.
- Error mapping is explicit for 400, 401, 403, 404, 405, 408, 429, and 5xx
  (`HTTPClientTransport.swift:380-427`).

#### SSE parsing, standalone GET, and reconnection

- On macOS, SSE parsing is delegated to EventSource's byte-level
  `stream.events` sequence (`HTTPClientTransport.swift:650`). The parser consumes
  one byte at a time and maintains line/event state across arbitrary chunks
  (`.build/checkouts/eventsource/Sources/EventSource/AsyncEventsSequence.swift:23-49`,
  `.../EventSource.swift:153-204`). It supports LF, CRLF, CR, multiple `data:`
  lines, multiple events, IDs, retry fields, comments, and final partial events.
- The EventSource tests explicitly cover multiple events and events split across
  chunks (`AsyncEventsSequenceTests.swift:30-55`, `202-259`). Actual resolved
  parser version is 1.5.1.
- When streaming is enabled, the GET listener waits for the first session ID or
  `sseInitializationTimeout`, then proceeds even after timeout
  (`HTTPClientTransport.swift:469-509`). A slow/no initialize can therefore cause
  repeated unauthorized/sessionless GETs rather than an outward transport
  failure.
- The GET reconnect loop runs until disconnect. After the first attempt it waits
  the server-provided retry interval, default 3000 ms
  (`HTTPClientTransport.swift:511-563`). Connection errors are logged and
  swallowed; they do **not** finish `receive()` or fail another public task.
  This means a dead resident app while the shim is otherwise idle can leave the
  output pump waiting forever unless Pippin supplies a liveness supervisor.
- GET uses `Last-Event-ID` when available (`HTTPClientTransport.swift:602-607`).
  `processSSE` stores IDs from both POST SSE and GET SSE in one actor-wide
  `lastEventID` (`HTTPClientTransport.swift:89-93`, `666-668`). This is intended
  to support a POST stream being resumed through GET, but stream switching and
  concurrent POST/GET IDs are subtle and are not covered by an HTTP-client
  reconnection test. Treat reconnect/session-resume as a required integration
  test, not as proven merely by the code comments.
- The HTTP client GET-SSE tests verify session header use and LF/CRLF event
  parsing (`HTTPClientTransportTests.swift:982-1103`), but they return a finite
  mock body and do not test reconnect or chunked network delivery.

#### Notifications and server-initiated messages

- Client-to-server notifications and client responses are ordinary raw POSTs.
  Pippin's `StatefulHTTPServerTransport` classifies them, yields them to the
  server, and returns 202 with no body
  (`StatefulHTTPServerTransport.swift:234-243`). The shim should emit nothing to
  stdout for that HTTP exchange.
- Server notifications and server-to-client requests are routed by the server
  transport to the standalone GET SSE stream
  (`StatefulHTTPServerTransport.swift:135-154`, `418-428`). The HTTP client emits
  their SSE `data` values through `receive()`, so the shim can forward them
  without knowing their methods or types.
- A response to a server-initiated request goes from stdio to HTTP as a POST and
  receives 202, which is also covered by the raw transport behavior.

#### DELETE and session termination

There is **no DELETE code path** in `HTTPClientTransport.swift`; a source search
finds no `DELETE` or `httpMethod = "DELETE"`. `disconnect()` only invalidates the
URLSession (`HTTPClientTransport.swift:197-214`). In contrast, the server
transport supports DELETE and terminates all streams/state
(`StatefulHTTPServerTransport.swift:365-383`, `554-580`). Pippin's `ServerHost`
then removes the session (`Sources/PippinServer/ServerHost.swift:139-156`).

Therefore Pippin must send a small Foundation `URLSession` DELETE **before**
disconnecting the SDK transport when `sessionID` exists. Required headers for
the current server are Authorization and `MCP-Session-Id`; `Accept` and
`Content-Type` validators intentionally do nothing for DELETE
(`HTTPRequestValidation.swift:79-127`, `136-154`). The DELETE is best-effort on
normal EOF/shutdown; process kill still relies on the resident server's timeout
sweep.

#### Are raw frames exposed and suitable for the relay?

**Yes, at the JSON-RPC frame layer.** `send(Data)` places the bytes directly in
the POST body, and `receive()` yields either the raw JSON body or each extracted
SSE `data` payload. It does not expose raw HTTP responses or raw SSE wire bytes.
For SDK-to-SDK traffic, the server puts a complete UTF-8 JSON-RPC object in one
SSE `data:` field (`HTTPServerTypes.swift:200-207`), so the yielded Data is fit
for stdio forwarding without JSON decode/re-encode.

Caveats to "byte-for-byte": SSE parsing necessarily converts event data through
`String` and rejoins multiple `data:` lines with LF. JSON-RPC is UTF-8, so this is
semantically correct, and Pippin's server emits one data line. It is not a raw
HTTP/SSE framing relay.

### 2. `StdioTransport`: server/client behavior and framing

The exact initializer is (`StdioTransport.swift:60-83`):

```swift
public init(
    input: FileDescriptor = FileDescriptor.standardInput,
    output: FileDescriptor = FileDescriptor.standardOutput,
    logger: Logger? = nil
)
```

- The transport has no client/server mode and no `Process` member. The same actor
  can be passed to `Client.connect`, `Server.start`, or used directly. Its default
  descriptors are the shim process's own stdin/stdout, so it does **not** spawn a
  child (`StdioTransport.swift:50-83`).
- Upstream's round-trip test constructs two instances over crossed pipes, uses
  one for `Server` and one for `Client`, and otherwise treats them identically
  (`RoundtripTests.swift:19-36`, `99-105`).
- `connect()` sets both descriptors non-blocking and starts its background read
  loop (`StdioTransport.swift:85-105`). It does not restore the previous fd flags
  on disconnect.
- Input is buffered in 4096-byte reads. Each LF ends a frame; the LF is stripped,
  empty frames are ignored, and each non-empty frame is yielded as raw `Data`
  without JSON validation (`StdioTransport.swift:131-176`). A final non-newline
  partial frame is discarded at EOF, consistent with newline-delimited stdio.
  With CRLF, the retained frame includes the CR byte; valid JSON decoders accept
  it as trailing whitespace.
- `send(_:)` appends exactly one LF, handles partial writes, and retries EAGAIN
  (`StdioTransport.swift:189-222`).
- `receive()` publicly returns the raw complete-frame stream
  (`StdioTransport.swift:224-233`).
- Upstream tests verify the output newline and input newline removal
  (`StdioTransportTests.swift:23-68`). They do not cover multiple frames in one
  read, a frame spanning reads, CRLF, or a partial frame at EOF; those are useful
  Pippin relay regressions.

Thus `StdioTransport()` can wrap the shim's own stdin/stdout exactly as required,
and its raw Data frames are directly suitable for the HTTP transport.

### 3. `Client`/`Server` APIs and transparent-proxy limits

The public registration surfaces are strongly typed:

```swift
// Client.swift:331-350
public func onNotification<N: Notification>(
    _ type: N.Type,
    handler: @escaping @Sendable (Message<N>) async throws -> Void
) async -> Self

public func withMethodHandler<M: Method>(
    _ type: M.Type,
    handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
) -> Self

// Server.swift:341-360
public func withMethodHandler<M: Method>(
    _ type: M.Type,
    handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
) -> Self

public func onNotification<N: Notification>(
    _ type: N.Type,
    handler: @escaping @Sendable (Message<N>) async throws -> Void
) -> Self
```

`Method` and `Notification` each require a compile-time associated parameter
type and static method name (`Messages.swift:22-30`, `299-305`). The SDK has
type-erased `AnyMethod`, `AnyRequest`, `AnyResponse`, `AnyNotification`, and
`AnyMessage`, but they have no public access modifier and are internal to the
`MCP` module (`Messages.swift:32-37`, `154-165`, `275-295`, `307-321`,
`387-388`). The type-erased handler boxes are internal too.

Consequences from actual dispatch code:

- `Client` ignores notifications without a registered typed handler and returns
  `methodNotFound` for unregistered server requests (`Client.swift:987-1045`).
- `Server` returns `methodNotFound` for unregistered requests and ignores
  unregistered notifications (`Server.swift:738-779`, `849-877`).
- `Client.connect(transport:)` starts consuming the transport and automatically
  sends its own `initialize` plus `notifications/initialized`
  (`Client.swift:205-284`, `642-665`). It would terminate transparency even if a
  wildcard handler existed.

There is no public wildcard handler, raw request hook, generic proxy, or
transport-to-transport relay abstraction in tag 0.12.1. A repository-wide search
of `Sources/` found no relay/bridge/proxy implementation and no receive-to-send
pump. The only reusable abstraction is the raw `Transport` protocol, so Pippin
must supply the two small pump loops itself.

One lifecycle nuance: only `Client._initialize()` updates an
`HTTPClientTransport` to the negotiated protocol version
(`Client.swift:657-661`). A raw relay does not parse the initialize response, so
the HTTP transport keeps its initializer's default `2025-11-25` header. Pippin's
current `ProtocolVersionValidator` accepts any supported header rather than
requiring it to equal the session's negotiated version
(`HTTPRequestValidation.swift:157-191`), so this is viable for the current
Pippin endpoint. It is a limitation on claiming the shim is a generic proxy for
arbitrary stricter upstream servers or older protocol clients.

### 4. Smallest viable Step 7 implementation

#### Recommended ownership by layer

| Concern | Owner | Reason/source |
|---|---|---|
| stdin newline detection and stdout newline append | SDK `StdioTransport` | Already complete and raw-Data based. |
| HTTP POST construction and response-status handling | SDK `HTTPClientTransport` | Sends unmodified frame body and handles JSON/SSE/202. |
| SSE event extraction and chunk boundaries | SDK HTTP transport + resolved EventSource 1.5.1 | Byte-incremental parser already linked by `MCP`. |
| `MCP-Session-Id` capture and use | SDK `HTTPClientTransport` | Public read-only session state and automatic request headers. |
| Bearer header insertion | Pippin request modifier | Static local bearer does not need OAuth machinery. |
| Endpoint decode, stale PID decision, app launch | Pippin + Foundation | No transport API covers process discovery/startup. |
| Bounded readiness polling | Pippin + Foundation `URLSession`/clock | `HTTPClientTransport.connect()` does no I/O. |
| Bidirectional relay and task/error coordination | Pippin | SDK has no relay abstraction. |
| Normal session termination | Pippin + Foundation DELETE | SDK HTTP client never sends DELETE. |
| Actionable errors and secret redaction | Pippin stderr policy | Transport errors are generic and GET reconnect errors are swallowed. |

#### Recommended flow

1. Decode only `host`, `port`, `token`, and `pid` from the private 0600 endpoint
   file. If absent, malformed, stale, or unreachable, invoke `/usr/bin/open -b
   io.github.is52hertz.pippin` via Foundation `Process` (fixed executable and
   arguments; no shell), then poll until a fresh endpoint responds or a single
   bounded deadline expires. Keep decode/probe errors generic; never interpolate
   the token or the decoded endpoint object.
2. A safe HTTP readiness probe is an authenticated GET to `/mcp` without a
   session ID. Current `ServerHost` authenticates first, then deliberately returns
   400 "Missing Mcp-Session-Id" for a reachable non-initialize request
   (`Sources/PippinServer/ServerHost.swift:128-174`). Treat the expected HTTP
   response as reachable; distinguish it from connection refusal/timeout and
   401. The probe creates no MCP session.
3. Construct `StdioTransport()` and `HTTPClientTransport(endpoint: endpoint,
   streaming: true, requestModifier: bearerModifier, logger: nil)`, then connect
   both. Do not use SDK `Client` or `Server`.
4. Start the HTTP-to-stdio pump immediately: iterate `await http.receive()` and
   `try await stdio.send(frame)`. This carries initialize responses, tool
   responses, notifications, and server requests without decoding.
5. Start the stdio-to-HTTP pump. Send the first stdin frame synchronously so the
   initialize POST finishes and the transport captures its session ID before
   later frames can race ahead. Preserve lifecycle order through the following
   initialized notification. After initialization, do not serialize every POST
   behind a long-running tool request: `HTTPClientTransport.send` waits until a
   POST SSE response closes, so a purely sequential pump would block concurrent
   calls and, critically, `notifications/cancelled`. Use structured child tasks
   with a small bounded number of outstanding sends, while continuing to pass the
   original Data unchanged.
6. Supervise the resident PID or perform a low-frequency bounded liveness check.
   This is necessary because the SDK's standalone GET loop swallows errors and
   reconnects forever; otherwise killing Pippin while idle can look like a hung
   shim. A POST failure, stdin EOF, liveness failure, or output failure should
   cancel both pumps and produce one distinct stderr message.
7. On normal stdin EOF/shutdown, if `await http.sessionID` is non-nil, send an
   authenticated Foundation DELETE first. Then disconnect HTTP and stdio, cancel
   remaining tasks, and exit. On abrupt process death, the server's timeout sweep
   remains the fallback.

This implementation parses transport framing and the private endpoint file, but
does not parse or rewrite JSON-RPC payloads. The first-frame/lifecycle gate,
session ID, in-flight send tasks, SSE cursor, and readiness deadline are all
ephemeral process state.

### 5. Tests to adapt and protocol edge cases

#### Relevant upstream tests

| Upstream source | What to adapt |
|---|---|
| `StdioTransportTests.swift:23-68` | Assert stdin LF stripping and exactly one stdout LF around unchanged Data. Extend with split reads, multiple frames/read, CRLF, empty lines, and EOF partial frame. |
| `RoundtripTests.swift:19-36`, `99-105` | Use crossed pipes to prove side neutrality and no child process. Replace typed endpoints with the two relay pumps. |
| `HTTPClientTransportTests.swift:175-215` | Direct `application/json` POST response becomes one stdio frame. |
| `HTTPClientTransportTests.swift:217-298`, `921-978` | Initial session capture, subsequent header, and 404 session clearing. |
| `HTTPClientTransportTests.swift:982-1103` | Standalone GET SSE plus LF/CRLF extraction; retain bearer/session header assertions. |
| `HTTPClientTransportTests.swift:1253-1294` | Bearer request modifier on every request. Add an explicit assertion for GET as well as POST. |
| `HTTPClientTransportTests.swift:2363-2394` | Protocol-version header behavior. |
| `HTTPServerTransportTests.swift:349-397` | Notification enters receive stream and HTTP returns 202 with no response frame. |
| `HTTPServerTransportTests.swift:401-470` | POST request returns SSE and the matching JSON-RPC response closes/routes through it. |
| `HTTPServerTransportTests.swift:475-540` | Standalone GET SSE and server-initiated notification routing. |
| `HTTPServerTransportTests.swift:543-560` | Only one standalone GET per session (second is 409). |
| `HTTPServerTransportTests.swift:564-613` | DELETE returns 200, closes the session, and later requests are 404. |
| `HTTPServerTransportTests.swift:788-847` | Last-Event-ID replay, extended to exercise the HTTP client's reconnect behavior rather than server-only behavior. |
| `AsyncEventsSequenceTests.swift:30-55`, `202-259` | Multiple SSE events and arbitrary chunk boundaries in the actual parser used by the SDK. |

#### Required Pippin edge matrix

1. **202 notification/client response:** stdio input frame is posted unchanged;
   202 with no body produces no stdout frame and does not fail.
2. **Direct JSON response:** `application/json` body becomes exactly one
   newline-terminated stdout frame.
3. **POST SSE response:** priming empty event is suppressed; one JSON-RPC data
   event becomes one stdout frame; the POST task completes when SSE closes.
4. **Multi-event POST SSE:** each non-empty SSE event becomes a separate stdout
   frame in event order. This is not covered by the SDK HTTP-client tests even
   though `processSSE` supports it.
5. **Chunk boundaries:** split `id:`, `data:`, UTF-8 scalars, and blank-line
   delimiters across network chunks; assert complete frames only. EventSource
   unit tests cover its parser, but the bridge should have at least one
   end-to-end split-delivery regression.
6. **Standalone GET SSE:** after initialization, server notifications and
   server-to-client requests reach stdout while no POST is active; bearer and
   session headers are present.
7. **Reconnect:** drop GET after an event ID, verify retry/Last-Event-ID, no
   duplicate/lost notification, and correct recovery after a POST stream closes.
   This is the least-proven SDK path.
8. **Session termination:** stdin EOF triggers one DELETE with bearer + session
   header before transport invalidation; server session count drops; no DELETE
   occurs before a session exists.
9. **Startup failures:** separate messages and nonzero exits for launch failure,
   malformed/missing endpoint after launch, readiness timeout, 401/token mismatch,
   stale PID, and runtime resident death. No case prints the token or hangs.
10. **Concurrency/cancellation:** after initialization, hold one POST SSE request
    open and send `notifications/cancelled` plus another request; prove they are
    posted without waiting for the first response.

Additional inherited limitation: `StdioTransport` documents batch frames, and
the SDK `Server` core can decode batches, but `StatefulHTTPServerTransport`'s
HTTP-boundary `JSONRPCMessageKind` only accepts a top-level JSON object
(`HTTPServerTypes.swift:240-260`). A stdio JSON-RPC batch array relayed unchanged
to the current Pippin HTTP endpoint is rejected before the core sees it. Standard
MCP lifecycle/tool traffic is object-per-frame, but the shim should not claim
full batch transparency unless the server transport limitation is separately
addressed.

### 6. Dependency and security conclusion

**Existing dependencies are sufficient.** No missing API requires an unapproved
package:

- `MCP` 0.12.1 exposes both transports and the raw `Transport` contract.
- Its already-resolved EventSource 1.5.1 dependency handles macOS SSE parsing.
- Foundation covers JSON endpoint decoding, `URLSession` readiness and DELETE,
  monotonic/bounded waits, filesystem access, `Process`, and stderr bytes.
- The existing resident server already owns NIO; the shim does not need to
  import or depend on NIO.

Security constraints for implementation:

- Bearer token: decode once into process memory, capture only in the request
  modifier/DELETE request, never include in errors, logs, stdout, diagnostics,
  command arguments, environment, or another file. Use `logger: nil` for both
  transports.
- Stdout: JSON-RPC frames only. Every diagnostic goes to stderr and must be
  independently actionable without echoing request data or headers.
- State: no persistence, cache, audit data, tool data, Apple Event data, SQLite
  data, EventKit objects, or TCC access. Only endpoint/framing/session/liveness
  state lives for the shim process lifetime.
- App launch: fixed `/usr/bin/open` executable and fixed bundle identifier; no
  shell and no user-controlled command construction.

### Related specs and task contracts

- `.trellis/tasks/08-17-pippin-skeleton-transport/prd.md`: S4, AC3, AC4, AC8,
  and the no-hang/actionable-failure requirement.
- `.trellis/tasks/08-17-pippin-skeleton-transport/design.md`: §4 shim topology;
  refine "no state" to no persistent/domain state as explained above.
- `.trellis/tasks/08-17-pippin-skeleton-transport/implement.md`: Step 7 and the
  Step 9 HTTP-vs-shim tool-list parity check.
- `.trellis/tasks/08-17-pippin-mcp-server/design.md`: §2 process/transport
  topology and §11 security boundary.
- `.trellis/spec/guides/cross-layer-thinking-guide.md`: framing and session
  headers are cross-layer contracts; validation belongs at boundaries.
- `.trellis/spec/guides/code-reuse-thinking-guide.md`: use the SDK's existing
  framing/SSE machinery and avoid reimplementing it in the shim.

### External references

- [Official swift-sdk release 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) — tag/commit identity.
- [HTTPClientTransport.swift at tag 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/HTTPClientTransport.swift) — reviewed HTTP source.
- [StdioTransport.swift at tag 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/StdioTransport.swift) — reviewed stdio source.
- [Transport.swift at tag 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transport.swift) — raw Data transport contract.
- [StatefulHTTPServerTransport.swift at tag 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/HTTPServer/StatefulHTTPServerTransport.swift) — reviewed server-side edge behavior.
- [EventSource 1.5.1 parser source](https://github.com/mattt/EventSource/blob/1.5.1/Sources/EventSource/AsyncEventsSequence.swift) — resolved transitive SSE parser.

## Caveats / Not Found

- No public wildcard method/notification API was found in SDK `Client` or
  `Server`; all useful type erasers are internal.
- No SDK transport relay/bridge/proxy abstraction was found.
- No HTTP-client DELETE/session-termination API was found.
- No HTTP-client test was found for 202/no-body, POST SSE, multi-event SSE,
  network chunk splits, DELETE, or reconnect/Last-Event-ID. Server and
  EventSource tests cover pieces, not the complete client-to-Pippin bridge.
- `HTTPClientTransport.connect()` is not readiness; its GET retry loop can hide
  resident death indefinitely. Pippin must supply bounded startup probing and a
  runtime liveness signal to satisfy AC8.
- Direct transport relay keeps the HTTP protocol header at the initializer's
  version because no `Client` decodes negotiation. This works with the current
  Pippin validator but narrows generic-proxy claims.
- JSON-RPC batch arrays are not transparent through the current stateful HTTP
  server classifier.
- No code was modified, compiled, or run for Step 7 during this research. The
  conclusions are source-level; the implementation still needs the edge matrix
  above against the packaged shim and resident server.
