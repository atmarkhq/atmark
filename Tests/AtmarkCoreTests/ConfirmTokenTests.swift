import Foundation
import Testing

@testable import AtmarkCore

@Suite("Confirm token lifecycle")
struct ConfirmTokenTests {
    private let tool = "atmark_reminders_delete"
    private let session = "session-A"
    private let ids = ["R1", "R2"]

    @Test("a freshly minted token authorises exactly its own request")
    func happyPath() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)
        try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ids)
    }

    @Test("a token is single-use")
    func singleUse() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)
        try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ids)

        // A confirmation that survives its first use is not a confirmation.
        await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ids)
        }
    }

    @Test("an expired token is refused")
    func expiry() async throws {
        let clock = MutableClock()
        let store = ConfirmTokenStore(ttl: 120, now: clock.now)
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)

        clock.advance(by: 121)
        let error = await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ids)
        }
        #expect(error?.code == .confirmationInvalid)
    }

    @Test("a token still valid one second before expiry works")
    func justBeforeExpiry() async throws {
        let clock = MutableClock()
        let store = ConfirmTokenStore(ttl: 120, now: clock.now)
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)
        clock.advance(by: 119)
        try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ids)
    }

    @Test("a token from another session is refused")
    func sessionBinding() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)

        // One client's confirmation must not authorise another client's delete.
        let error = await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: tool, sessionID: "session-B", ids: ids)
        }
        #expect(error?.detail == "session")
    }

    @Test("a token from another tool is refused")
    func toolBinding() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ids)
        let error = await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: "atmark_mail_delete", sessionID: session, ids: ids)
        }
        #expect(error?.detail == "tool")
    }

    @Test("swapping the items after confirmation is refused")
    func idSetBinding() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ["R1", "R2"])

        // The attack this exists to stop: preview two harmless items, then submit
        // the token with a different, larger set.
        let error = await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ["R1", "R2", "R3"])
        }
        #expect(error?.detail == "items")
    }

    @Test("removing an item from the set is refused too")
    func subsetIsAlsoRefused() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ["R1", "R2"])
        await #expect(throws: AtmarkError.self) {
            try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ["R1"])
        }
    }

    @Test("the same set in a different order is accepted")
    func orderIndependence() async throws {
        let store = ConfirmTokenStore()
        let minted = try await store.mint(tool: tool, sessionID: session, ids: ["R1", "R2", "R3"])
        try await store.consume(token: minted.token, tool: tool, sessionID: session, ids: ["R3", "R1", "R2"])
    }

    @Test("an unknown token is refused")
    func unknownToken() async {
        let store = ConfirmTokenStore()
        await #expect(throws: AtmarkError.self) {
            try await store.consume(token: "made-up", tool: tool, sessionID: session, ids: ids)
        }
    }

    @Test("the store never holds the identifiers themselves")
    func hashIsOpaque() {
        let hash = ConfirmTokenStore.hash(ids: ["R1", "secret-reminder-id"])
        #expect(!hash.contains("secret-reminder-id"))
        #expect(hash.count == 64)
    }

    @Test("an empty id list is refused — there is no delete-all form")
    func emptyIdsRefused() async {
        let store = ConfirmTokenStore()
        let error = await #expect(throws: AtmarkError.self) {
            try await store.mint(tool: tool, sessionID: session, ids: [])
        }
        #expect(error?.code == .invalidArgument)
    }

    @Test("more items than the cap is refused")
    func capEnforced() async {
        let store = ConfirmTokenStore()
        let many = (0...ConfirmTokenStore.maximumItemsPerCall).map { "R\($0)" }
        await #expect(throws: AtmarkError.self) {
            try await store.mint(tool: tool, sessionID: session, ids: many)
        }
    }

    @Test("duplicate identifiers are refused")
    func duplicatesRefused() async {
        // Duplicates would make both the count cap and the preview lie.
        let store = ConfirmTokenStore()
        await #expect(throws: AtmarkError.self) {
            try await store.mint(tool: tool, sessionID: session, ids: ["R1", "R1"])
        }
    }

    @Test("expired entries do not accumulate")
    func expiredEntriesArePurged() async throws {
        let clock = MutableClock()
        let store = ConfirmTokenStore(ttl: 60, now: clock.now)
        for index in 0..<5 {
            _ = try await store.mint(tool: tool, sessionID: session, ids: ["R\(index)"])
        }
        #expect(await store.count == 5)

        clock.advance(by: 61)
        _ = try await store.mint(tool: tool, sessionID: session, ids: ["fresh"])
        #expect(await store.count == 1)
    }
}

/// A clock the test moves by hand. Sleeping through a real TTL would make the
/// suite slow and flaky for no added confidence.
final class MutableClock: @unchecked Sendable {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let lock = NSLock()

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
