import Foundation
import Testing

@testable import AtmarkCore

private final class ToolContextFailurePlan: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [AuditLog.FailurePoint]

    init(_ failures: [AuditLog.FailurePoint]) {
        self.failures = failures
    }

    func shouldFail(_ point: AuditLog.FailurePoint) -> Bool {
        lock.withLock {
            guard failures.first == point else { return false }
            failures.removeFirst()
            return true
        }
    }
}

private actor MutationStartBarrier {
    private var first: CheckedContinuation<Void, Never>?

    func arrive() async {
        if let first {
            self.first = nil
            first.resume()
            return
        }
        await withCheckedContinuation { first = $0 }
    }
}

/// The two-phase delete protocol lives in one place so every destructive tool in
/// every module inherits the same guarantees. These exercise it as a module will
/// actually call it.
@Suite("Two-phase delete protocol")
struct ToolContextTests {
    private func context(
        session: String = "session-A",
        capabilities: Capabilities = .all,
        writes: Bool = true,
        auditURL: URL,
        audit: AuditLog? = nil,
        confirmTokens: ConfirmTokenStore = ConfirmTokenStore()
    ) -> ToolContext {
        ToolContext(
            sessionID: session,
            capabilities: capabilities,
            config: Config(modules: ["reminders": .init(enabled: true, writes: writes)]),
            confirmTokens: confirmTokens,
            audit: audit ?? AuditLog(url: auditURL)
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "atmark ctx \(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "audit.jsonl")
    }

    @Test("without a token nothing is performed and a token is returned")
    func previewArmPerformsNothing() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)

        var performed = false
        let result = try await context.confirmDestructive(
            tool: "atmark_reminders_delete",
            module: "reminders",
            ids: ["R1", "R2"],
            confirmToken: nil,
            preview: { .object(["count": .int(2)]) },
            perform: { performed = true; return [:] }
        )

        #expect(!performed)
        guard case .object(let fields) = result else {
            Issue.record("expected an object"); return
        }
        #expect(fields["confirmation_required"] == .bool(true))
        #expect(fields["preview"] == .object(["count": .int(2)]))
        if case .string(let token) = fields["confirm_token"] ?? .null {
            #expect(!token.isEmpty)
        } else {
            Issue.record("no confirm_token returned")
        }
        #expect(fields["expires_at"] != nil)
    }

    @Test("the returned token authorises exactly that delete")
    func confirmArmPerforms() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)
        let ids = ["R1", "R2"]

        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        var performed = false
        _ = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: token,
            preview: { .object([:]) },
            perform: { performed = true; return ["deleted": .int(2)] })

        #expect(performed)
    }

    @Test("a token cannot be replayed")
    func tokenIsSingleUse() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)
        let ids = ["R1"]

        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        _ = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: token,
            preview: { .object([:]) }, perform: { [:] })

        var performedTwice = false
        await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ids, confirmToken: token,
                preview: { .object([:]) },
                perform: { performedTwice = true; return [:] })
        }
        #expect(!performedTwice)
    }

    @Test("swapping the items after the preview does not delete them")
    func itemSwapIsRefused() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)

        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ["R1"], confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        // The attack: preview one harmless item, confirm a larger set.
        var performed = false
        await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ["R1", "R2", "R3"], confirmToken: token,
                preview: { .object([:]) },
                perform: { performed = true; return [:] })
        }
        #expect(!performed)
    }

    @Test("writes disabled blocks the protocol before any preview runs")
    func gateRunsFirst() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(writes: false, auditURL: url)

        var previewed = false
        let error = await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ["R1"], confirmToken: nil,
                preview: { previewed = true; return .object([:]) },
                perform: { [:] })
        }
        #expect(error?.code == .writesDisabled)
        // Not even the preview runs: a disabled module should not be touched.
        #expect(!previewed)
    }

    @Test("a read-only connection cannot reach the protocol at all")
    func readOnlyCapabilityRefused() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(capabilities: .readOnly, auditURL: url)

        let error = await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ["R1"], confirmToken: nil,
                preview: { .object([:]) }, perform: { [:] })
        }
        #expect(error?.code == .permissionDenied)
    }

    @Test("every arm of the protocol leaves an audit entry")
    func auditCoversEveryArm() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)
        let ids = ["R1"]

        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        _ = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: token,
            preview: { .object([:]) }, perform: { [:] })

        _ = try? await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: "bogus",
            preview: { .object([:]) }, perform: { [:] })

        let outcomes = try await context.audit.entries().map(\.outcome)
        // preview, durable delete intent/outcome, bad token
        #expect(outcomes == [.refused, .intent, .succeeded, .refused])
    }

    @Test("a failing delete is recorded as failed, not silently dropped")
    func failureIsAudited() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)

        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ["R1"], confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        _ = try? await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ["R1"], confirmToken: token,
            preview: { .object([:]) },
            perform: { throw AtmarkError(.backendUnavailable, detail: "eventkit") })

        #expect(try await context.audit.entries().map(\.outcome) == [.refused, .intent, .failed])
    }

    @Test(
        "intent append or synchronize failure performs nothing",
        arguments: [AuditLog.FailurePoint.intentAppend, .intentSynchronize]
    )
    func intentFailureFailsClosed(point: AuditLog.FailurePoint) async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = ToolContextFailurePlan([point])
        let audit = AuditLog(url: url, shouldFail: plan.shouldFail)
        let context = context(auditURL: url, audit: audit)
        var performed = false

        let error = await #expect(throws: AtmarkError.self) {
            _ = try await context.performMutation(tool: "t", module: "reminders") {
                performed = true
                return ["changed": .bool(true)]
            }
        }

        #expect(performed == false)
        #expect(error?.code == .backendUnavailable)
        #expect(error?.detail == "audit_log")
        #expect(error?.hint == "Atmark could not record a durable mutation intent. Fix audit-log storage, then retry; no Apple data was changed.")
    }

    @Test("ordinary writes check the mutation gate before journal or perform")
    func ordinaryWriteGateRunsFirst() async {
        let url = URL(fileURLWithPath: "/dev/null/impossible/audit.jsonl")
        let context = context(writes: false, auditURL: url)
        var performed = false

        let error = await #expect(throws: AtmarkError.self) {
            _ = try await context.performMutation(tool: "t", module: "reminders") {
                performed = true
                return [:]
            }
        }

        #expect(error?.code == .writesDisabled)
        #expect(performed == false)
    }

    @Test(
        "outcome append or synchronize failure returns the real degraded success",
        arguments: [AuditLog.FailurePoint.outcomeAppend, .outcomeSynchronize]
    )
    func outcomeFailureIsTruthful(point: AuditLog.FailurePoint) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = ToolContextFailurePlan([point])
        let audit = AuditLog(url: url, shouldFail: plan.shouldFail)
        let context = context(auditURL: url, audit: audit)

        let result = try await context.performMutation(
            tool: "t", module: "reminders", ids: ["R1"]
        ) {
            ["changed": .bool(true), "id": .string("R1")]
        }

        #expect(result["changed"] == .bool(true))
        #expect(result["id"] == .string("R1"))
        #expect(result["audit_degraded"] == .bool(true))
        #expect(result["audit_hint"] == .string(
            "Mutation succeeded. Audit outcome unavailable; do not retry. Later mutations stay blocked until audit storage recovers."
        ))
        #expect(await audit.isHealthy() == false)
    }

    @Test("an unhealthy journal blocks once, then recovers through the next durable intent")
    func healthLatchBlocksAndRecovers() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = ToolContextFailurePlan([.outcomeAppend, .intentAppend])
        let audit = AuditLog(url: url, shouldFail: plan.shouldFail)
        let context = context(auditURL: url, audit: audit)

        let first = try await context.performMutation(tool: "first", module: "reminders") {
            ["changed": .string("first")]
        }
        #expect(first["audit_degraded"] == .bool(true))

        var blockedPerformed = false
        let blocked = await #expect(throws: AtmarkError.self) {
            _ = try await context.performMutation(tool: "blocked", module: "reminders") {
                blockedPerformed = true
                return [:]
            }
        }
        #expect(blocked?.detail == "audit_log")
        #expect(blockedPerformed == false)

        let recovered = try await context.performMutation(tool: "recovered", module: "reminders") {
            ["changed": .string("recovered")]
        }
        #expect(recovered == ["changed": .string("recovered")])
        #expect(await audit.isHealthy() == true)
    }

    @Test("a failed perform retains correlated intent and failed outcome")
    func failedPerformIsCorrelated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = context(auditURL: url)
        let expected = AtmarkError(.backendUnavailable, detail: "eventkit")

        let error = await #expect(throws: AtmarkError.self) {
            _ = try await context.performMutation(tool: "t", module: "reminders", ids: ["R1"]) {
                throw expected
            }
        }
        #expect(error == expected)

        let entries = try await context.audit.entries()
        #expect(entries.map(\.outcome) == [.intent, .failed])
        #expect(entries[0].operationID != nil)
        #expect(entries[0].operationID == entries[1].operationID)
    }

    @Test("a successful in-flight outcome does not clear an unhealthy latch")
    func inFlightOutcomeDoesNotClearLatch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = ToolContextFailurePlan([.outcomeAppend])
        let audit = AuditLog(url: url, shouldFail: plan.shouldFail)
        let context = context(auditURL: url, audit: audit)
        let barrier = MutationStartBarrier()

        async let first = context.performMutation(tool: "first", module: "reminders") {
            await barrier.arrive()
            return ["operation": .string("first")]
        }
        async let second = context.performMutation(tool: "second", module: "reminders") {
            await barrier.arrive()
            return ["operation": .string("second")]
        }
        let results = try await [first, second]

        #expect(results.filter { $0["audit_degraded"] == .bool(true) }.count == 1)
        #expect(await audit.isHealthy() == false)

        _ = try await context.performMutation(tool: "recovery", module: "reminders") { [:] }
        #expect(await audit.isHealthy() == true)
    }

    @Test("a consumed confirmation token stays burned when intent fails")
    func tokenRemainsConsumedAfterIntentFailure() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = ToolContextFailurePlan([.intentAppend])
        let audit = AuditLog(url: url, shouldFail: plan.shouldFail)
        let tokens = ConfirmTokenStore()
        let context = context(auditURL: url, audit: audit, confirmTokens: tokens)
        let ids = ["R1"]
        let preview = try await context.confirmDestructive(
            tool: "t", module: "reminders", ids: ids, confirmToken: nil,
            preview: { .object([:]) }, perform: { [:] })
        guard case .object(let fields) = preview,
              case .string(let token) = fields["confirm_token"] ?? .null
        else { Issue.record("no token"); return }

        var performed = false
        let intentError = await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ids, confirmToken: token,
                preview: { .object([:]) }, perform: { performed = true; return [:] })
        }
        #expect(intentError?.detail == "audit_log")
        #expect(performed == false)

        let replayError = await #expect(throws: AtmarkError.self) {
            _ = try await context.confirmDestructive(
                tool: "t", module: "reminders", ids: ids, confirmToken: token,
                preview: { .object([:]) }, perform: { performed = true; return [:] })
        }
        #expect(replayError?.code == .confirmationInvalid)
        #expect(performed == false)
    }

    @Test("the gate is derived from the context, never stored separately")
    func gateIsConsistent() {
        let url = temporaryURL()
        let context = context(capabilities: .readOnly, auditURL: url)
        #expect(throws: AtmarkError.self) { try context.gate.check(.write, module: "reminders") }
        #expect(throws: Never.self) { try context.gate.check(.read, module: "reminders") }
    }
}
