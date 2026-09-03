import Foundation

/// One way of answering a capability.
public struct Backend<Value: Sendable>: Sendable {
    public let name: String
    /// Checked before running. A backend disabled by a failed schema probe or a
    /// missing permission reports unavailable rather than throwing on every call.
    public let isAvailable: @Sendable () async -> Bool
    public let run: @Sendable () async throws -> Value

    public init(
        name: String,
        isAvailable: @escaping @Sendable () async -> Bool = { true },
        run: @escaping @Sendable () async throws -> Value
    ) {
        self.name = name
        self.isAvailable = isAvailable
        self.run = run
    }
}

/// What answered, and whether the answer came the fast way.
public struct RoutedResult<Value: Sendable>: Sendable {
    public let value: Value
    public let backend: String
    /// True when a preferred backend was skipped or failed. Modules surface this
    /// so a slow or partial answer is visibly slow or partial rather than
    /// silently so.
    public let degraded: Bool
    /// Why the preferred backend was not used, when it was not.
    public let reason: String?
}

/// Tries backends in order and reports which one answered.
///
/// Routing is per *capability*, not per app: Mail search goes to SQLite while
/// Mail body fetch goes to AppleScript, because they have different fast paths.
///
/// The contract that matters: when every backend is unavailable or fails, this
/// throws. It never returns an empty value. A missing permission that surfaces as
/// "no results" is the single worst failure this system can produce, because it
/// is indistinguishable from a true answer (criterion A7).
public enum BackendRouter {
    public static func route<Value: Sendable>(
        _ backends: [Backend<Value>],
        capability: String
    ) async throws -> RoutedResult<Value> {
        var skipped: [String] = []
        var failures: [(name: String, error: AtmarkError)] = []

        for backend in backends {
            guard await backend.isAvailable() else {
                skipped.append(backend.name)
                continue
            }
            do {
                let value = try await backend.run()
                let degraded = !skipped.isEmpty || !failures.isEmpty
                return RoutedResult(
                    value: value,
                    backend: backend.name,
                    degraded: degraded,
                    reason: degraded ? Self.reason(skipped: skipped, failures: failures) : nil
                )
            } catch let error as AtmarkError {
                failures.append((backend.name, error))
            } catch {
                failures.append((backend.name, AtmarkError(.backendUnavailable, detail: backend.name)))
            }
        }

        // Surface the first real failure rather than a generic one: it is the
        // most specific thing we know, and it usually carries the actionable hint
        // (a missing permission, a not-running app).
        if let first = failures.first {
            throw first.error
        }
        throw AtmarkError(
            .backendUnavailable,
            detail: capability,
            hint: skipped.isEmpty
                ? "No backend is configured for \(capability)."
                : "Every backend for \(capability) is unavailable: \(skipped.joined(separator: ", ")). Check Atmark's status."
        )
    }

    private static func reason(
        skipped: [String],
        failures: [(name: String, error: AtmarkError)]
    ) -> String {
        var parts: [String] = []
        if !skipped.isEmpty {
            parts.append("unavailable: \(skipped.joined(separator: ", "))")
        }
        for failure in failures {
            parts.append("\(failure.name) failed: \(failure.error.code.rawValue)")
        }
        return parts.joined(separator: "; ")
    }
}
