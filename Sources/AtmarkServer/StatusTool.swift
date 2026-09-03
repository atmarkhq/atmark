import Foundation
import MCP
import AtmarkCore

/// What `atmark_status` reports. Assembled by `ServerHost`, which owns the live
/// values; the tool itself only renders.
public struct StatusSnapshot: Sendable {
    public let version: String
    public let host: String
    public let port: Int
    public let modules: [String: Config.ModuleConfig]
    public let sessionCount: Int
    public let capabilities: Capabilities
    public let permissions: PermissionSnapshot

    public init(
        version: String,
        host: String,
        port: Int,
        modules: [String: Config.ModuleConfig],
        sessionCount: Int,
        capabilities: Capabilities,
        permissions: PermissionSnapshot
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.modules = modules
        self.sessionCount = sessionCount
        self.capabilities = capabilities
        self.permissions = permissions
    }

    /// The rendered payload, before pruning.
    public var json: JSONValue {
        .object([
            "version": .string(version),
            "endpoint": .string("http://\(host):\(port)/mcp"),
            "sessions": .int(sessionCount),
            "capabilities": .array(capabilities.sorted().map { .string($0.rawValue) }),
            "permissions": permissions.json,
            "modules": .object(modules.mapValues { module in
                .object([
                    "enabled": .bool(module.enabled),
                    "writes": .bool(module.writes),
                ])
            }),
        ])
    }
}

public enum StatusTool {
    public static let name = "atmark_status"

    public static let definition = ToolDefinition(
        tool: Tool(
            name: name,
            title: "Atmark Status",
            // Terse by policy: this description is re-sent on every request of
            // every session, so prose here is a recurring cost.
            description: "Report Atmark's version, endpoint, modules, permissions, and what this connection may do.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "version": .object(["type": .string("string")]),
                    "endpoint": .object(["type": .string("string")]),
                    "sessions": .object(["type": .string("integer")]),
                    "capabilities": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "modules": .object(["type": .string("object")]),
                    "permissions": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "reminders": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("not_determined"),
                                    .string("denied"),
                                    .string("restricted"),
                                    .string("write_only"),
                                    .string("granted"),
                                    .string("unknown"),
                                ]),
                            ]),
                            "mail_automation": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("not_determined"),
                                    .string("denied"),
                                    .string("granted"),
                                    .string("unavailable"),
                                    .string("unknown"),
                                ]),
                            ]),
                            "full_disk_access": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("granted"),
                                    .string("denied"),
                                    .string("unavailable"),
                                    .string("unknown"),
                                ]),
                            ]),
                        ]),
                        "required": .array([
                            .string("reminders"),
                            .string("mail_automation"),
                            .string("full_disk_access"),
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "required": .array([
                    .string("version"),
                    .string("endpoint"),
                    .string("sessions"),
                    .string("capabilities"),
                    .string("modules"),
                    .string("permissions"),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        module: nil,
        requiredCapability: .read
    )
}
