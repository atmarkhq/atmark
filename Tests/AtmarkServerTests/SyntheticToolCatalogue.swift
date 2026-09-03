import MCP
import AtmarkCore

@testable import AtmarkServer

/// Test-only module tools. Production intentionally ships no Reminders or Mail
/// definitions yet, so registry and notification gating need a synthetic surface
/// until those module tasks land.
enum SyntheticToolCatalogue {
    static let definitions: [ToolDefinition] = [
        StatusTool.definition,
        definition("atmark_reminders_search", module: "reminders", capability: .read),
        definition("atmark_reminders_create", module: "reminders", capability: .write),
        definition("atmark_reminders_delete", module: "reminders", capability: .destructive),
        definition("atmark_mail_search", module: "mail", capability: .read),
    ]

    static let registry = ToolRegistry(catalogue: definitions)

    private static func definition(
        _ name: String,
        module: String,
        capability: Capability
    ) -> ToolDefinition {
        ToolDefinition(
            tool: Tool(name: name, description: nil, inputSchema: .object([:])),
            module: module,
            requiredCapability: capability
        )
    }
}
