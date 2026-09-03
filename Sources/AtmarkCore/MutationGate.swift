import Foundation

/// Re-checks at call time what the registry already enforced by omission.
///
/// The registry hides tools a caller may not use, which is the primary control.
/// This is the second one, and it is not redundant: a client may hold a cached
/// tool list from before the user turned writes off, and "absent from a list" is
/// not the same as "refuses to run".
public struct MutationGate: Sendable {
    private let config: Config
    private let capabilities: Capabilities

    public init(config: Config, capabilities: Capabilities) {
        self.config = config
        self.capabilities = capabilities
    }

    /// Both gates must open: the caller's token must carry the capability, and
    /// the module must be configured to allow it. Config wins over capability —
    /// a token that may write cannot write to a module with writes off.
    public func check(_ capability: Capability, module: String) throws {
        guard capabilities.contains(capability) else {
            throw AtmarkError(
                .permissionDenied,
                detail: capability.rawValue,
                hint: "This connection is not permitted to \(capability.rawValue). Use a token with that capability."
            )
        }
        guard let moduleConfig = config.modules[module], moduleConfig.enabled else {
            throw AtmarkError(
                .notFound,
                detail: module,
                hint: "The \(module) module is disabled. Enable it in Atmark's settings."
            )
        }
        if capability != .read {
            guard moduleConfig.writes else {
                throw AtmarkError(
                    .writesDisabled,
                    detail: module,
                    hint: "Writes are disabled for \(module). Enable them in Atmark's settings, then retry."
                )
            }
        }
    }
}
