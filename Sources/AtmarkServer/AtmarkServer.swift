import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import AtmarkCore
import AtmarkModules

/// Namespace for MCP server wiring: the HTTP listener, the session table, the
/// request validators, and the tool registry.
///
/// The MCP SDK's `StatefulHTTPServerTransport` binds no socket and serves exactly
/// one session, so this target owns both the listener (swift-nio) and the
/// `sessionID → (Server, transport)` table. Populated by steps 4–6.
public enum AtmarkServer {}
