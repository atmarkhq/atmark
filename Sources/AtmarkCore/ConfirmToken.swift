import CryptoKit
import Foundation

/// Two-phase confirmation for destructive tools.
///
/// A destructive tool called without a token performs nothing and returns a
/// preview plus a token; called with the token, it proceeds. The human approval
/// happens in the client's own tool-approval UI, which every target client has —
/// deliberately not MCP `elicitation`, which is unevenly implemented across them.
///
/// A token is only meaningful if it cannot be reused, cannot outlive the intent
/// that produced it, and cannot be pointed at a different set of items than the
/// one the user saw. All three are enforced here rather than left to each module.
public actor ConfirmTokenStore {
    public struct Minted: Sendable {
        public let token: String
        public let expiresAt: Date
    }

    private struct Entry {
        let tool: String
        let sessionID: String
        let idSetHash: String
        let expiresAt: Date
    }

    /// Short by design. The token exists to cover one round trip between a
    /// preview and its confirmation, not to be stored and used later.
    public static let defaultTTL: TimeInterval = 120

    /// Bounds a single destructive call. A cap is what makes "explicit ID lists
    /// only" meaningful — an unbounded list is a predicate with extra steps.
    public static let maximumItemsPerCall = 50

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(ttl: TimeInterval = ConfirmTokenStore.defaultTTL, now: @escaping @Sendable () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    /// Order-independent digest of the exact items the user was shown.
    ///
    /// Sorted first, so the same set presented in a different order still matches;
    /// hashed, so the store never holds the identifiers themselves.
    public static func hash(ids: [String]) -> String {
        let joined = ids.sorted().joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func mint(tool: String, sessionID: String, ids: [String]) throws -> Minted {
        try Self.validateItemCount(ids)
        purgeExpired()

        let token = Token.generate()
        let expiresAt = now().addingTimeInterval(ttl)
        entries[token] = Entry(
            tool: tool,
            sessionID: sessionID,
            idSetHash: Self.hash(ids: ids),
            expiresAt: expiresAt
        )
        return Minted(token: token, expiresAt: expiresAt)
    }

    /// Validates and burns the token in one step.
    ///
    /// Consuming on validation rather than after the delete is deliberate: a
    /// partially-completed delete that left the token alive would let a retry
    /// re-run it, and a token that survives its first use is not a confirmation.
    public func consume(token: String, tool: String, sessionID: String, ids: [String]) throws {
        try Self.validateItemCount(ids)
        purgeExpired()

        guard let entry = entries.removeValue(forKey: token) else {
            throw AtmarkError(
                .confirmationInvalid,
                detail: "token",
                hint: "The token expired or was already used. Call the tool without a confirm_token to get a fresh preview."
            )
        }
        guard entry.expiresAt > now() else {
            throw AtmarkError(.confirmationInvalid, detail: "expired")
        }
        guard entry.tool == tool else {
            // A token minted by one tool must not authorise another.
            throw AtmarkError(.confirmationInvalid, detail: "tool")
        }
        guard entry.sessionID == sessionID else {
            // One client's confirmation must not authorise another's delete.
            throw AtmarkError(.confirmationInvalid, detail: "session")
        }
        guard entry.idSetHash == Self.hash(ids: ids) else {
            throw AtmarkError(
                .confirmationInvalid,
                detail: "items",
                hint: "These are not the items the confirmation was issued for. Request a fresh preview."
            )
        }
    }

    private static func validateItemCount(_ ids: [String]) throws {
        guard !ids.isEmpty else {
            throw AtmarkError(
                .invalidArgument,
                detail: "ids",
                hint: "List the identifiers to act on explicitly. There is no delete-all form."
            )
        }
        guard ids.count <= maximumItemsPerCall else {
            throw AtmarkError(
                .invalidArgument,
                detail: "ids",
                hint: "At most \(maximumItemsPerCall) items per destructive call. Split the request."
            )
        }
        guard Set(ids).count == ids.count else {
            // Duplicates would make the count cap and the preview both lie.
            throw AtmarkError(.invalidArgument, detail: "ids", hint: "Identifiers must be unique.")
        }
    }

    private func purgeExpired() {
        let cutoff = now()
        entries = entries.filter { $0.value.expiresAt > cutoff }
    }

    public var count: Int { entries.count }
}
