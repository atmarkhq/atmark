import MCP
import AtmarkCore

/// One tool plus the conditions under which it exists at all.
public struct ToolDefinition: Sendable {
    public let tool: Tool
    /// The module this belongs to, or `nil` for tools that are part of the server
    /// itself and are not gated by module config.
    public let module: String?
    /// What a caller must hold to see it.
    public let requiredCapability: Capability

    public init(tool: Tool, module: String?, requiredCapability: Capability) {
        self.tool = tool
        self.module = module
        self.requiredCapability = requiredCapability
    }
}

/// Derives the visible tool list from `(Config, Capabilities)`.
///
/// A pure function of its inputs, which is what makes gating testable without a
/// transport, a client, or a permission grant. Note the *pair*: deriving from
/// config alone would work today, when one omnipotent token exists, and would
/// have to be unpicked at every call site the moment a second token with a
/// narrower tier appears (S9).
///
/// Gating is by absence, never by a tool that exists and refuses. A disabled tool
/// must not appear in `tools/list` at all — otherwise it keeps costing tokens on
/// every request and keeps inviting the model to call it (parent criterion A6).
public struct ToolRegistry: Sendable {
    private let catalogue: [ToolDefinition]

    public init(catalogue: [ToolDefinition]) {
        self.catalogue = catalogue
    }

    public func tools(config: Config, capabilities: Capabilities) -> [Tool] {
        catalogue
            .filter { isVisible($0, config: config, capabilities: capabilities) }
            .map(\.tool)
            .sorted { $0.name < $1.name }
    }

    private func isVisible(
        _ definition: ToolDefinition,
        config: Config,
        capabilities: Capabilities
    ) -> Bool {
        guard capabilities.contains(definition.requiredCapability) else { return false }

        guard let module = definition.module else {
            // Server-level tools are not gated by module config.
            return true
        }
        guard let moduleConfig = config.modules[module], moduleConfig.enabled else {
            return false
        }
        // A module with writes off contributes only its read-only tools, even to
        // a caller who holds write capability. Both gates must open.
        if definition.requiredCapability != .read {
            return moduleConfig.writes
        }
        return true
    }
}
