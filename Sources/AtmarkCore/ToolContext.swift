import Foundation

/// Everything a tool needs that is not its own arguments.
///
/// This exists because the safety primitives are only safe when they are used
/// together and consistently: a confirm token is meaningless without the session
/// that minted it, the gate is meaningless without the caller's capabilities, and
/// an audit trail with gaps is worse than none. Handing modules one context
/// rather than six separate objects is what stops each module inventing its own
/// arrangement of them.
///
/// Deliberately free of MCP types, so module code stays testable without a
/// transport and `AtmarkCore` keeps its import boundary.
public struct ToolContext: Sendable {
    /// The MCP session this call arrived on. Confirm tokens are bound to it, so
    /// one client's confirmation cannot authorise another client's delete.
    public let sessionID: String
    /// What the token presented on this connection may do.
    public let capabilities: Capabilities
    public let config: Config

    /// Shared across every session in the process — that sharing is the reason
    /// the process is resident.
    public let confirmTokens: ConfirmTokenStore
    public let audit: AuditLog
    public let appleScript: AppleScriptRunner

    public init(
        sessionID: String,
        capabilities: Capabilities,
        config: Config,
        confirmTokens: ConfirmTokenStore,
        audit: AuditLog,
        appleScript: AppleScriptRunner = AppleScriptRunner()
    ) {
        self.sessionID = sessionID
        self.capabilities = capabilities
        self.config = config
        self.confirmTokens = confirmTokens
        self.audit = audit
        self.appleScript = appleScript
    }

    /// Derived rather than stored, so it can never disagree with the config and
    /// capabilities it is built from.
    public var gate: MutationGate {
        MutationGate(config: config, capabilities: capabilities)
    }

    /// The single owner for ordinary mutation sequencing.
    public func performMutation(
        tool: String,
        module: String,
        ids: [String] = [],
        arguments: [String: String]? = nil,
        perform: () async throws -> [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        try gate.check(.write, module: module)
        return try await performMutationAfterGate(
            tool: tool,
            module: module,
            ids: ids,
            arguments: arguments,
            perform: perform
        )
    }

    /// The full two-phase delete protocol, in one place.
    ///
    /// Every destructive tool in every module routes through this, so the
    /// guarantees hold by construction instead of by each module remembering to
    /// check expiry, single use, tool, session, and item set. `perform` runs only
    /// after a token has been validated and burned.
    public func confirmDestructive(
        tool: String,
        module: String,
        ids: [String],
        confirmToken: String?,
        preview: () async throws -> JSONValue,
        perform: () async throws -> [String: JSONValue]
    ) async throws -> JSONValue {
        try gate.check(.destructive, module: module)

        guard let confirmToken else {
            // The preview arm performs nothing and returns the resolved list of
            // exactly what would go, plus the token to authorise it.
            let previewed = try await preview()
            let minted = try await confirmTokens.mint(tool: tool, sessionID: sessionID, ids: ids)
            await audit.record(tool: tool, module: module, ids: ids, outcome: .refused,
                               error: AtmarkError(.confirmationRequired))
            return .object([
                "confirmation_required": .bool(true),
                "confirm_token": .string(minted.token),
                "expires_at": .timestamp(minted.expiresAt),
                "preview": previewed,
            ])
        }

        do {
            try await confirmTokens.consume(
                token: confirmToken, tool: tool, sessionID: sessionID, ids: ids)
        } catch let error as AtmarkError {
            await audit.record(tool: tool, module: module, ids: ids, outcome: .refused, error: error)
            throw error
        }

        return .object(try await performMutationAfterGate(
            tool: tool,
            module: module,
            ids: ids,
            arguments: nil,
            perform: perform
        ))
    }

    private func performMutationAfterGate(
        tool: String,
        module: String,
        ids: [String],
        arguments: [String: String]?,
        perform: () async throws -> [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        let operationID: UUID
        do {
            operationID = try await audit.beginMutation(
                tool: tool,
                module: module,
                ids: ids,
                arguments: arguments
            )
        } catch {
            throw AtmarkError(
                .backendUnavailable,
                detail: "audit_log",
                hint: "Atmark could not record a durable mutation intent. Fix audit-log storage, then retry; no Apple data was changed."
            )
        }

        let result: [String: JSONValue]
        do {
            result = try await perform()
        } catch {
            let projected = error as? AtmarkError
                ?? AtmarkError(.backendUnavailable, detail: "operation")
            try? await audit.finishMutation(
                operationID: operationID,
                tool: tool,
                module: module,
                ids: ids,
                outcome: .failed,
                error: projected,
                arguments: arguments
            )
            throw error
        }

        do {
            try await audit.finishMutation(
                operationID: operationID,
                tool: tool,
                module: module,
                ids: ids,
                outcome: .succeeded,
                arguments: arguments
            )
            return result
        } catch {
            var degraded = result
            degraded["audit_degraded"] = .bool(true)
            degraded["audit_hint"] = .string(
                "Mutation succeeded. Audit outcome unavailable; do not retry. Later mutations stay blocked until audit storage recovers."
            )
            return degraded
        }
    }
}
