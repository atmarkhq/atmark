import Foundation

/// One page of results plus the cursor to continue, if there is more.
public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    /// Present only when more results exist. Absent means the list is exhausted —
    /// an agent should never have to make an extra call to discover that.
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Offset pagination behind an opaque cursor.
///
/// The cursor is opaque so its encoding stays ours to change; callers must not
/// construct or arithmetic on one. It is deliberately not a security boundary —
/// it encodes an offset, not an authorization — so it is encoded, not signed.
public enum Pagination {
    /// Applied when a caller does not ask for a size.
    public static let defaultLimit = 25
    /// The server-side hard cap. A caller asking for more gets this instead of an
    /// error: clamping keeps a well-meaning oversized request working, while the
    /// cap is what actually protects the token budget.
    public static let maximumLimit = 100

    public static func clamp(limit: Int?) -> Int {
        guard let limit else { return defaultLimit }
        return min(max(limit, 1), maximumLimit)
    }

    public static func encodeCursor(offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    public static func decodeCursor(_ cursor: String) throws -> Int {
        guard
            let data = Data(base64Encoded: cursor),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("offset:"),
            let offset = Int(text.dropFirst("offset:".count)),
            offset >= 0
        else {
            throw AtmarkError(
                .invalidArgument,
                detail: "cursor",
                hint: "Pass a next_cursor exactly as returned by a previous call, or omit it to start over."
            )
        }
        return offset
    }

    /// Slices an already-materialized collection.
    ///
    /// Suited to backends that hand back a whole result set anyway — EventKit and
    /// AppleScript both do. A backend that can page natively should do that
    /// instead of loading everything to throw most of it away.
    public static func page<Element>(
        _ elements: [Element],
        limit: Int?,
        cursor: String?
    ) throws -> Page<Element> {
        let size = clamp(limit: limit)
        let offset = try cursor.map { try decodeCursor($0) } ?? 0

        guard offset < elements.count else {
            // A cursor past the end is exhaustion, not an error: the underlying
            // collection may legitimately have shrunk between calls.
            return Page(items: [], nextCursor: nil)
        }

        let end = min(offset + size, elements.count)
        let items = Array(elements[offset..<end])
        return Page(
            items: items,
            nextCursor: end < elements.count ? encodeCursor(offset: end) : nil
        )
    }
}
