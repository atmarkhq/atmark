import Foundation
import Logging
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import AtmarkCore

/// The loopback HTTP/1.1 listener.
///
/// The public `MCP` product has no importable socket or multi-session host:
/// `StatefulHTTPServerTransport` is an `HTTPRequest → HTTPResponse` handler and
/// binds nothing. This socket/type adapter follows the conformance `HTTPApp` from
/// swift-sdk 0.12.1, commit `a0ae212ebf6eab5f754c3129608bc5557637e605`;
/// that host is part of the non-importable `MCPConformanceServer` executable.
///
/// Retained Atmark deviations are product policy or framework adaptation:
/// loopback-only binding with configured-port fallback, exact endpoint matching,
/// repeated-header joining, immediate SSE chunk flushing, and off-main dispatch
/// stay here. `ServerHost` retains authentication-before-routing, bearer/session
/// and capability pinning, resident shared state, per-session tool policy,
/// expiry, list-changed notifications, and status. JSON-RPC, protocol validation,
/// SSE/resumability, and each transport session remain owned by the SDK.
public actor HTTPListener {
    private let host: String
    private let requestedPort: Int
    private let endpointPath: String
    private let host_: ServerHost
    private let logger: Logger

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init(
        host: String,
        port: Int,
        endpointPath: String = "/mcp",
        serverHost: ServerHost,
        logger: Logger = Logger(label: "atmark.http")
    ) {
        self.host = host
        self.requestedPort = port
        self.endpointPath = endpointPath
        self.host_ = serverHost
        self.logger = logger
    }

    /// Binds and returns the port actually in use.
    ///
    /// A port conflict falls back to an ephemeral port rather than failing to
    /// start: the port is published in `endpoint.json` anyway, so nothing depends
    /// on it being the configured one, and refusing to launch over a busy port
    /// would be a worse outcome than moving.
    @discardableResult
    public func start() async throws -> Int {
        guard Config.isLoopback(host) else {
            // Constraint C1, enforced once more at the point of binding. Config
            // validation should have caught this; a listener that trusts it to
            // have happened is one refactor away from binding 0.0.0.0.
            throw AtmarkError(
                .invalidArgument,
                detail: "http.bind",
                hint: "Atmark binds loopback only. Use 127.0.0.1 or ::1."
            )
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        let serverHost = host_
        let path = endpointPath
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        AtmarkHTTPHandler(serverHost: serverHost, endpointPath: path)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let bound: Channel
        do {
            bound = try await bootstrap.bind(host: host, port: requestedPort).get()
        } catch where requestedPort != 0 {
            logger.warning("Port \(requestedPort) unavailable; falling back to an ephemeral port")
            bound = try await bootstrap.bind(host: host, port: 0).get()
        }

        channel = bound
        let port = bound.localAddress?.port ?? requestedPort
        await host_.setBoundAddress(host: host, port: port)
        logger.info("Listening on http://\(host):\(port)\(endpointPath)")
        return port
    }

    public func stop() async {
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
    }
}

// MARK: - NIO adapter

/// Converts between NIO's HTTP types and the SDK's framework-agnostic ones.
/// Holds no logic of its own beyond path matching.
private final class AtmarkHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        var head: HTTPRequestHead
        var body: ByteBuffer
    }

    private let serverHost: ServerHost
    private let endpointPath: String
    private var state: RequestState?

    init(serverHost: ServerHost, endpointPath: String) {
        self.serverHost = serverHost
        self.endpointPath = endpointPath
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            state = RequestState(head: head, body: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            state?.body.writeBuffer(&buffer)
        case .end:
            guard let current = state else { return }
            state = nil
            nonisolated(unsafe) let ctx = context
            // Deliberately not hopped to the main actor: this process also runs a
            // SwiftUI menu bar app, and serving HTTP on the main actor would put
            // agent traffic in contention with the UI.
            Task { await self.dispatch(current, context: ctx) }
        }
    }

    private func dispatch(_ request: RequestState, context: ChannelHandlerContext) async {
        let uri = request.head.uri
        let path = String(uri.split(separator: "?").first ?? Substring(uri))

        guard path == endpointPath else {
            await write(.error(statusCode: 404, .invalidRequest("Not Found")),
                        version: request.head.version, context: context)
            return
        }

        let response = await serverHost.handle(makeRequest(request, path: path))
        await write(response, version: request.head.version, context: context)
    }

    private func makeRequest(_ state: RequestState, path: String) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            // Repeated headers are joined per RFC 7230 rather than last-wins.
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        var body: Data?
        if state.body.readableBytes > 0,
           let bytes = state.body.getBytes(at: 0, length: state.body.readableBytes) {
            body = Data(bytes)
        }

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func write(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let loop = ctx.eventLoop

        @Sendable func writeHead() {
            var head = HTTPResponseHead(
                version: version,
                status: HTTPResponseStatus(statusCode: response.statusCode)
            )
            for (name, value) in response.headers {
                head.headers.add(name: name, value: value)
            }
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
        }

        switch response {
        case .stream(let stream, _):
            loop.execute {
                writeHead()
                ctx.flush()
            }
            // Each SSE chunk is flushed as it arrives; buffering would defeat the
            // point of streaming a long-running tool call back to the client.
            do {
                for try await chunk in stream {
                    loop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // The stream ended early; close the response cleanly below.
            }
            loop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }

        default:
            let body = response.bodyData
            loop.execute {
                writeHead()
                if let body {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
