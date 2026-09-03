import MCP
import AtmarkCore

/// Maps the core's transport-independent JSON type onto the SDK's.
///
/// This adapter is the entire price of keeping `AtmarkCore` free of an MCP
/// import, and it is worth paying: DTO shaping and pruning stay unit-testable
/// without a transport.
extension Value {
    init(_ json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(Value.init))
        case .object(let fields): self = .object(fields.mapValues(Value.init))
        }
    }

    /// Prunes before converting, so nulls and empties never reach the wire.
    /// An entirely empty payload becomes an empty object rather than `null`,
    /// since a tool result of `null` reads as a failure.
    static func pruned(_ json: JSONValue) -> Value {
        Value(json.pruned() ?? .object([:]))
    }
}
