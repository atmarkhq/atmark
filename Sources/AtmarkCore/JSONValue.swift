import Foundation

/// A JSON value, owned by the core so DTO shaping stays testable without the MCP
/// SDK. `AtmarkServer` maps this onto the SDK's own value type at the boundary.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Drops fields that carry no information, per the DTO conventions: nulls,
    /// empty strings, and empty arrays and objects, recursively.
    ///
    /// `false` and `0` are values, not absences, and are kept. This distinction is
    /// the whole reason pruning is a deliberate operation rather than a filter on
    /// falsiness — a reminder whose `completed` is `false` must not lose the field.
    public func pruned() -> JSONValue? {
        switch self {
        case .null:
            return nil
        case .string(let value):
            return value.isEmpty ? nil : self
        case .bool, .int, .double:
            return self
        case .array(let elements):
            let kept = elements.compactMap { $0.pruned() }
            return kept.isEmpty ? nil : .array(kept)
        case .object(let fields):
            let kept = fields.compactMapValues { $0.pruned() }
            return kept.isEmpty ? nil : .object(kept)
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Timestamps

extension JSONValue {
    /// ISO-8601 with an explicit offset. Locale-formatted dates are never emitted:
    /// an agent has to be able to parse what it reads back into a `_get` call.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> JSONValue {
        .string(ISO8601.string(from: date, timeZone: timeZone))
    }
}

public enum ISO8601 {
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        // Accept fractional seconds on input; we never emit them.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
