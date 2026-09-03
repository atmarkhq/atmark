import Foundation

/// What a caller is allowed to do. A *set*, never a boolean.
///
/// Batch one provisions exactly one token holding all three, so nothing today
/// distinguishes them. The shape exists anyway because batch four adds remote
/// access with per-token tiers, where a token reachable from outside this machine
/// must resolve to `read` alone — the prompt-injection blast radius of a web agent
/// must not include destructive tools. Threading a capability set through now
/// costs one parameter; retrofitting it later costs every call site that assumed
/// a single omnipotent caller.
public enum Capability: String, Codable, CaseIterable, Sendable, Comparable {
    case read
    case write
    case destructive

    public static func < (lhs: Capability, rhs: Capability) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public typealias Capabilities = Set<Capability>

extension Capabilities {
    /// What the single local token gets in batch one.
    public static let all: Capabilities = Set(Capability.allCases)
    /// The shape batch four's remote token will take.
    public static let readOnly: Capabilities = [.read]
}

/// Who a presented bearer token resolves to.
public struct TokenIdentity: Hashable, Sendable {
    /// Names the caller in logs and in `atmark_status`. Never the token itself.
    public let label: String
    public let capabilities: Capabilities

    public init(label: String, capabilities: Capabilities) {
        self.label = label
        self.capabilities = capabilities
    }
}

/// Resolves bearer tokens to identities.
///
/// Immutable after construction, so lookup is synchronous — the SDK's request
/// validators are synchronous, and making this an actor would mean either
/// blocking in a validator or restructuring the request path around a lookup that
/// never actually needs to await anything.
///
/// This is deliberately *not* a permission system yet: no minting UI, no
/// revocation, no persistence. Only the shape.
public struct TokenStore: Sendable {
    private let identities: [String: TokenIdentity]

    public init(_ identities: [String: TokenIdentity] = [:]) {
        self.identities = identities
    }

    /// The batch-one store: one locally-generated token that can do everything.
    public static func local(token: String) -> TokenStore {
        TokenStore([token: TokenIdentity(label: "local", capabilities: .all)])
    }

    public func identity(for token: String) -> TokenIdentity? {
        identities[token]
    }

    /// Labels only. Exists so status output and logs can describe who may connect
    /// without ever handling the tokens themselves.
    public var labels: [String] {
        identities.values.map(\.label).sorted()
    }
}

// MARK: - Token generation

public enum Token {
    /// A 256-bit token, hex-encoded.
    ///
    /// `SystemRandomNumberGenerator` is documented as cryptographically secure on
    /// Apple platforms; this is the same entropy source `SecRandomCopyBytes` draws
    /// from, without pulling Security into the core.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016lx", UInt64.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
