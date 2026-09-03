import Foundation
import SQLite3

/// Read-only access to another app's private SQLite store.
///
/// This tier exists purely for speed — AppleScript search over a real mailbox is
/// too slow to be usable — and it is designed on the assumption that it will
/// break. The schemas are private, undocumented, and change across OS releases,
/// and reading them needs Full Disk Access. So: open read-only, resolve versioned
/// paths at runtime, probe the schema before trusting it, and always have
/// somewhere else to go.
///
/// The one outcome that is never acceptable is zero rows. A missing permission or
/// a moved column must surface as an error a user can act on, not as an empty
/// result the agent will report as "you have no mail" (criterion A7).
public final class SQLiteReader: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "atmark.sqlite")

    public let path: String

    public init(path: String) throws {
        self.path = path

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw AtmarkError(
                .backendUnavailable,
                detail: (path as NSString).lastPathComponent,
                hint: Self.isPermissionProblem(path: path)
                    ? "Grant Atmark Full Disk Access in System Settings › Privacy & Security, then retry."
                    : "Could not open the data store: \(message)"
            )
        }

        guard let handle, sqlite3_db_readonly(handle, "main") == 1 else {
            sqlite3_close(handle)
            self.handle = nil
            throw AtmarkError(
                .backendUnavailable,
                detail: (path as NSString).lastPathComponent,
                hint: "The data store could not be verified as read-only. Atmark will not access it."
            )
        }

        guard sqlite3_busy_timeout(handle, 250) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            self.handle = nil
            throw AtmarkError(
                .backendUnavailable,
                detail: (path as NSString).lastPathComponent,
                hint: "Could not configure bounded SQLite lock waiting: \(message)"
            )
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Distinguishes "not allowed to read it" from "it is not there", because the
    /// two need different things from the user.
    private static func isPermissionProblem(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
            && !FileManager.default.isReadableFile(atPath: path)
    }

    // MARK: - Versioned path resolution

    /// Resolves a path containing a single `*` component, newest match last.
    ///
    /// Mail's store lives under `~/Library/Mail/V10/`, and the version changes
    /// with macOS. A hard-coded path is a guaranteed future outage, so it is
    /// resolved at runtime and its absence is a first-class error.
    public static func resolveVersionedPath(_ pattern: String) throws -> String {
        let expanded = (pattern as NSString).expandingTildeInPath
        let parts = expanded.components(separatedBy: "/")
        guard let wildcardIndex = parts.firstIndex(where: { $0.contains("*") }) else {
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw AtmarkError(.backendUnavailable, detail: "path", hint: "\(expanded) does not exist.")
            }
            return expanded
        }

        let base = parts[..<wildcardIndex].joined(separator: "/")
        let pattern = parts[wildcardIndex]
        let remainder = parts[(wildcardIndex + 1)...].joined(separator: "/")

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: base)
        } catch {
            throw AtmarkError(
                .backendUnavailable,
                detail: "path",
                hint: "Could not list \(base). Full Disk Access may be required."
            )
        }

        let prefix = pattern.components(separatedBy: "*").first ?? ""
        let candidates = contents
            .filter { $0.hasPrefix(prefix) }
            // Version directories sort naturally by their numeric suffix; the
            // newest is what the running OS uses.
            .sorted { lhs, rhs in
                let l = Int(lhs.dropFirst(prefix.count)) ?? -1
                let r = Int(rhs.dropFirst(prefix.count)) ?? -1
                return l < r
            }

        guard let newest = candidates.last else {
            throw AtmarkError(
                .backendUnavailable,
                detail: "path",
                hint: "No directory matching \(pattern) under \(base)."
            )
        }

        let resolved = remainder.isEmpty ? "\(base)/\(newest)" : "\(base)/\(newest)/\(remainder)"
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw AtmarkError(.backendUnavailable, detail: "path", hint: "\(resolved) does not exist.")
        }
        return resolved
    }

    // MARK: - Schema probe

    /// Confirms the tables and columns this backend actually reads are present.
    ///
    /// Run once at startup. A failed probe disables the backend and records why,
    /// which is the difference between a degraded search and a wrong answer.
    public func probe(_ expected: [String: [String]]) -> Result<Void, AtmarkError> {
        for (table, columns) in expected {
            let found: Set<String>
            do {
                found = Set(try query("PRAGMA table_info(\(Self.quoteIdentifier(table)))") { row in
                    row.string(at: 1)
                }.compactMap { $0 })
            } catch let error as AtmarkError {
                return .failure(error)
            } catch {
                return .failure(AtmarkError(.backendUnavailable, detail: table))
            }

            guard !found.isEmpty else {
                return .failure(AtmarkError(
                    .backendUnavailable,
                    detail: table,
                    hint: "The data store does not have a \(table) table. Its schema has changed; Atmark is using its fallback."
                ))
            }
            let missing = Set(columns).subtracting(found)
            guard missing.isEmpty else {
                return .failure(AtmarkError(
                    .backendUnavailable,
                    detail: table,
                    hint: "\(table) is missing \(missing.sorted().joined(separator: ", ")). The schema has changed; Atmark is using its fallback."
                ))
            }
        }
        return .success(())
    }

    /// Quotes an identifier. Only ever applied to table names this repository
    /// authors — `PRAGMA` will not accept a bound parameter, so identifiers
    /// cannot be parameterized and must never come from a caller.
    static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Queries

    public struct Row {
        fileprivate let statement: OpaquePointer

        public func string(at index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }

        public func int(at index: Int32) -> Int? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, index))
        }

        public func double(at index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, index)
        }
    }

    /// Runs a query with bound parameters.
    ///
    /// `sql` is authored here; every caller-supplied value goes through
    /// `parameters` and is bound, never interpolated. There is no overload that
    /// takes an assembled string, so there is no convenient way to get this wrong.
    public func query<T>(
        _ sql: String,
        parameters: [SQLiteValue] = [],
        map: (Row) -> T
    ) throws -> [T] {
        try queue.sync {
            guard let handle else {
                throw AtmarkError(.backendUnavailable, detail: "sqlite", hint: "The data store is closed.")
            }

            var statement: OpaquePointer?
            let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepareStatus == SQLITE_OK else {
                throw Self.queryError(
                    handle: handle,
                    status: prepareStatus,
                    fallbackHint: "The schema may have changed."
                )
            }
            defer { sqlite3_finalize(statement) }

            for (offset, parameter) in parameters.enumerated() {
                parameter.bind(to: statement, at: Int32(offset + 1))
            }

            var results: [T] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                results.append(map(Row(statement: statement!)))
                step = sqlite3_step(statement)
            }

            // Checking the terminal code is not pedantry. Treating anything that
            // is not SQLITE_ROW as "finished" would turn a read-only violation,
            // a corrupted page, or a vanished file into a silently truncated or
            // empty result — indistinguishable from a true answer, which is the
            // one failure mode this tier must never produce (criterion A7).
            guard step == SQLITE_DONE else {
                throw Self.queryError(
                    handle: handle,
                    status: step,
                    fallbackHint: "The query did not complete."
                )
            }
            return results
        }
    }

    private static func queryError(
        handle: OpaquePointer,
        status: Int32,
        fallbackHint: String
    ) -> AtmarkError {
        let primaryCode = status & 0xff
        if primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED {
            return AtmarkError(
                .backendUnavailable,
                detail: "sqlite",
                hint: "The data store is busy. Retry shortly; Atmark may use its fallback if contention continues."
            )
        }
        let message = String(cString: sqlite3_errmsg(handle))
        return AtmarkError(
            .backendUnavailable,
            detail: "sqlite",
            hint: "Query failed: \(message). \(fallbackHint)"
        )
    }
}

/// A value that can be bound to a query parameter. Exists so `query` cannot be
/// handed a pre-formatted string.
public enum SQLiteValue: Sendable {
    case text(String)
    case int(Int)
    case double(Double)
    case null

    fileprivate func bind(to statement: OpaquePointer?, at index: Int32) {
        // SQLITE_TRANSIENT: sqlite must copy the bytes, since the Swift string's
        // buffer does not outlive this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch self {
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
        case .int(let value): sqlite3_bind_int64(statement, index, Int64(value))
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .null: sqlite3_bind_null(statement, index)
        }
    }
}
