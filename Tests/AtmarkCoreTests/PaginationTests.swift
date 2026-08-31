import Foundation
import Testing

@testable import AtmarkCore

@Suite("Pagination")
struct PaginationTests {
    @Test("an absent limit uses the default")
    func defaultLimit() {
        #expect(Pagination.clamp(limit: nil) == Pagination.defaultLimit)
    }

    @Test("an oversized limit is clamped, not rejected")
    func clampsAboveCap() {
        // Clamping keeps a well-meaning oversized request working; the cap is
        // what actually protects the token budget.
        #expect(Pagination.clamp(limit: 10_000) == Pagination.maximumLimit)
    }

    @Test("a nonsensical limit becomes the smallest useful one", arguments: [0, -1, -100])
    func clampsBelowOne(limit: Int) {
        #expect(Pagination.clamp(limit: limit) == 1)
    }

    @Test("cursors round-trip")
    func cursorRoundTrip() throws {
        for offset in [0, 1, 25, 9_999] {
            #expect(try Pagination.decodeCursor(Pagination.encodeCursor(offset: offset)) == offset)
        }
    }

    @Test("cursors are opaque rather than a bare number")
    func cursorIsOpaque() {
        // Callers must not do arithmetic on it, so it must not look like they can.
        #expect(Pagination.encodeCursor(offset: 25) != "25")
    }

    @Test("a malformed cursor is an invalid_argument, not a crash or a silent reset", arguments: [
        "25", "", "not-base64!!", "b2Zmc2V0Oi0x",   // the last decodes to "offset:-1"
    ])
    func rejectsBadCursor(cursor: String) {
        let error = #expect(throws: AtmarkError.self) { try Pagination.decodeCursor(cursor) }
        #expect(error?.code == .invalidArgument)
        #expect(error?.detail == "cursor")
    }

    @Test("the first page reports more results")
    func firstPage() throws {
        let page = try Pagination.page(Array(1...10), limit: 3, cursor: nil)
        #expect(page.items == [1, 2, 3])
        #expect(page.nextCursor != nil)
    }

    @Test("paging walks the whole collection exactly once")
    func walksEverything() throws {
        let source = Array(1...10)
        var seen: [Int] = []
        var cursor: String? = nil
        var guardRail = 0

        repeat {
            let page = try Pagination.page(source, limit: 3, cursor: cursor)
            seen.append(contentsOf: page.items)
            cursor = page.nextCursor
            guardRail += 1
            #expect(guardRail < 100, "pagination did not terminate")
        } while cursor != nil

        #expect(seen == source)
    }

    @Test("the last page carries no cursor")
    func lastPageHasNoCursor() throws {
        let page = try Pagination.page(Array(1...6), limit: 3, cursor: Pagination.encodeCursor(offset: 3))
        #expect(page.items == [4, 5, 6])
        // Absent means exhausted: the agent must not need an extra call to learn it.
        #expect(page.nextCursor == nil)
    }

    @Test("an exact multiple of the page size still ends cleanly")
    func exactMultiple() throws {
        let page = try Pagination.page(Array(1...3), limit: 3, cursor: nil)
        #expect(page.items == [1, 2, 3])
        #expect(page.nextCursor == nil)
    }

    @Test("an empty collection yields an empty page")
    func emptyCollection() throws {
        let page = try Pagination.page([Int](), limit: 10, cursor: nil)
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("a cursor past the end is exhaustion, not an error")
    func cursorPastEnd() throws {
        // The underlying collection may legitimately have shrunk between calls.
        let page = try Pagination.page(Array(1...3), limit: 10, cursor: Pagination.encodeCursor(offset: 99))
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("a request above the cap returns at most the cap")
    func respectsCapEndToEnd() throws {
        let page = try Pagination.page(Array(1...500), limit: 10_000, cursor: nil)
        #expect(page.items.count == Pagination.maximumLimit)
    }
}
