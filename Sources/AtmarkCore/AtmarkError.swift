import Foundation

/// A tool failure, in the compact machine-readable shape agents receive.
///
/// Errors are tokens too, so the wire form stays small: a stable `code`, an
/// optional `detail` naming *what* failed, and a `hint` saying what the user can
/// do about it. Every code carries a hint — a missing permission that surfaces as
/// an empty result set is the specific failure this model exists to prevent
/// (parent criterion A7).
public struct AtmarkError: Error, Hashable, Sendable {
    public enum Code: String, Codable, CaseIterable, Sendable {
        case permissionDenied = "permission_denied"
        case backendUnavailable = "backend_unavailable"
        case appNotRunning = "app_not_running"
        case timeout
        case notFound = "not_found"
        case invalidArgument = "invalid_argument"
        case confirmationRequired = "confirmation_required"
        case confirmationInvalid = "confirmation_invalid"
        case writesDisabled = "writes_disabled"
        case syncPending = "sync_pending"

        /// What the user can do about it. Phrased as an instruction, not a
        /// restatement of the failure — the agent relays this to a human who can
        /// act on it, so "grant X in Y" beats "permission was denied".
        public var hint: String {
            switch self {
            case .permissionDenied:
                "Grant Atmark access in System Settings › Privacy & Security, then retry."
            case .backendUnavailable:
                "The data source is unreachable. Check Atmark's status for which one and why."
            case .appNotRunning:
                "Open the app and retry. Atmark does not launch apps on your behalf."
            case .timeout:
                "The app did not respond in time. Retry, or narrow the request."
            case .notFound:
                "Check the identifier. List the containing collection to get current ones."
            case .invalidArgument:
                "Check the argument against the tool's input schema and retry."
            case .confirmationRequired:
                "Call the tool again with the confirm_token from this response to proceed."
            case .confirmationInvalid:
                "The token expired, was already used, or does not match these items. Request a fresh preview."
            case .writesDisabled:
                "Enable writes for this module in Atmark's settings, then retry."
            case .syncPending:
                "iCloud has not finished syncing this change. Retry shortly."
            }
        }
    }

    public let code: Code
    /// Names the specific thing that failed — a backend, a field, an identifier.
    /// Never carries argument values; those belong nowhere near an error string.
    public let detail: String?
    public let hint: String

    /// Creates an error. The hint defaults to the code's, and is overridable only
    /// where a call site can say something more actionable.
    public init(_ code: Code, detail: String? = nil, hint: String? = nil) {
        self.code = code
        self.detail = detail
        self.hint = hint ?? code.hint
    }
}

// MARK: - Wire form

extension AtmarkError: Codable {
    private enum RootKey: String, CodingKey { case error }
    private enum BodyKey: String, CodingKey { case code, detail, hint }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKey.self)
        var body = root.nestedContainer(keyedBy: BodyKey.self, forKey: .error)
        try body.encode(code, forKey: .code)
        // Pruned rather than emitted as null, per the DTO conventions.
        try body.encodeIfPresent(detail, forKey: .detail)
        try body.encode(hint, forKey: .hint)
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        let body = try root.nestedContainer(keyedBy: BodyKey.self, forKey: .error)
        code = try body.decode(Code.self, forKey: .code)
        detail = try body.decodeIfPresent(String.self, forKey: .detail)
        hint = try body.decodeIfPresent(String.self, forKey: .hint) ?? code.hint
    }
}

extension AtmarkError: CustomStringConvertible {
    public var description: String {
        detail.map { "\(code.rawValue)(\($0)): \(hint)" } ?? "\(code.rawValue): \(hint)"
    }
}
