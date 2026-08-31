import CryptoKit
import Darwin
import Foundation

/// A private local operation journal, not a tamper-evident or compliance audit.
/// Non-mutation entries are best-effort; every mutation requires a synchronized
/// intent before its side effects may begin.
public actor AuditLog {
    public enum Outcome: String, Codable, Sendable {
        case intent
        case succeeded
        case failed
        case refused
    }

    public struct Entry: Codable, Sendable {
        public let timestamp: String
        public let tool: String
        public let module: String?
        public let ids: [String]
        public let outcome: Outcome
        public let error: String?
        /// Correlates a required intent with its outcome. Optional so existing
        /// JSONL entries remain decodable.
        public let operationID: UUID?
        /// A digest, never raw values or Apple data.
        public let argumentsDigest: String?
    }

    enum FailurePoint: CaseIterable, Sendable {
        case intentAppend
        case intentSynchronize
        case outcomeAppend
        case outcomeSynchronize
        case rotationSynchronizeCurrent
        case rotationRemovePrevious
        case rotationMoveCurrent
        case rotationSynchronizeMovedDirectory
        case rotationCreateCurrent
        case rotationSynchronizeCreatedDirectory
    }

    public static let maximumBytes = 5 * 1024 * 1024

    private enum RequiredWrite {
        case intent
        case outcome
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private let rotationThreshold: Int
    private let shouldFail: @Sendable (FailurePoint) -> Bool
    private var healthy = true

    public init(url: URL = AuditLog.defaultURL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
        self.rotationThreshold = Self.maximumBytes
        self.shouldFail = { _ in false }
    }

    init(
        url: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        rotationThreshold: Int = AuditLog.maximumBytes,
        shouldFail: @escaping @Sendable (FailurePoint) -> Bool
    ) {
        self.url = url
        self.now = now
        self.rotationThreshold = rotationThreshold
        self.shouldFail = shouldFail
    }

    public static var defaultURL: URL {
        Config.defaultDirectory.appending(path: "audit.jsonl")
    }

    public static func digest(_ arguments: [String: String]) -> String {
        let canonical = arguments.keys.sorted()
            .map { "\($0)=\(arguments[$0] ?? "")" }
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Best-effort by design: previews and refusals do not mutate Apple data.
    public func record(
        tool: String,
        module: String? = nil,
        ids: [String] = [],
        outcome: Outcome,
        error: AtmarkError? = nil,
        arguments: [String: String]? = nil
    ) {
        let entry = makeEntry(
            operationID: nil,
            tool: tool,
            module: module,
            ids: ids,
            outcome: outcome,
            error: error,
            arguments: arguments
        )
        try? append(entry, requiredWrite: nil)
    }

    /// Appends and synchronizes the mutation intent. A failure leaves the health
    /// latch closed and propagates so callers can fail before side effects.
    func beginMutation(
        tool: String,
        module: String? = nil,
        ids: [String] = [],
        arguments: [String: String]? = nil
    ) throws -> UUID {
        let operationID = UUID()
        let entry = makeEntry(
            operationID: operationID,
            tool: tool,
            module: module,
            ids: ids,
            outcome: .intent,
            error: nil,
            arguments: arguments
        )
        do {
            try append(entry, requiredWrite: .intent)
            healthy = true
            return operationID
        } catch {
            healthy = false
            throw error
        }
    }

    /// Appends and synchronizes an outcome. Success never clears an unhealthy
    /// latch: only a later mutation's own synchronized intent is a recovery probe.
    func finishMutation(
        operationID: UUID,
        tool: String,
        module: String? = nil,
        ids: [String] = [],
        outcome: Outcome,
        error: AtmarkError? = nil,
        arguments: [String: String]? = nil
    ) throws {
        precondition(outcome != .intent && outcome != .refused)
        let entry = makeEntry(
            operationID: operationID,
            tool: tool,
            module: module,
            ids: ids,
            outcome: outcome,
            error: error,
            arguments: arguments
        )
        do {
            try append(entry, requiredWrite: .outcome)
        } catch {
            healthy = false
            throw error
        }
    }

    func isHealthy() -> Bool { healthy }

    private func makeEntry(
        operationID: UUID?,
        tool: String,
        module: String?,
        ids: [String],
        outcome: Outcome,
        error: AtmarkError?,
        arguments: [String: String]?
    ) -> Entry {
        Entry(
            timestamp: ISO8601.string(from: now()),
            tool: tool,
            module: module,
            ids: ids,
            outcome: outcome,
            error: error.map { $0.detail ?? $0.code.rawValue },
            operationID: operationID,
            argumentsDigest: arguments.map { AuditLog.digest($0) }
        )
    }

    private func append(_ entry: Entry, requiredWrite: RequiredWrite?) throws {
        let line = try JSONEncoder().encode(entry) + Data("\n".utf8)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path(percentEncoded: false)
        )
        if requiredWrite != nil {
            // Repeat these metadata barriers even when the paths already exist.
            // A previous required append may have created them and then failed
            // its directory sync; existence alone is not a durability proof.
            try Self.synchronizeDirectory(directory.deletingLastPathComponent())
        }

        try rotateIfNeeded(requiredWrite: requiredWrite)
        try ensureCurrentFile()
        if requiredWrite != nil {
            try Self.synchronizeDirectory(directory)
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        if requiredWrite != nil {
            try isolateUnterminatedTail(handle)
        }
        try handle.seekToEnd()

        if let requiredWrite {
            try inject(requiredWrite == .intent ? .intentAppend : .outcomeAppend)
        }
        try handle.write(contentsOf: line)
        if let requiredWrite {
            try inject(requiredWrite == .intent ? .intentSynchronize : .outcomeSynchronize)
            try handle.synchronize()
        }
    }

    private func ensureCurrentFile() throws {
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return
        }
        guard FileManager.default.createFile(
            atPath: path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func isolateUnterminatedTail(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        guard try handle.read(upToCount: 1) != Data("\n".utf8) else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.synchronize()
    }

    private func rotateIfNeeded(requiredWrite: RequiredWrite?) throws {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.intValue >= rotationThreshold
        else { return }

        let directory = url.deletingLastPathComponent()
        let rotated = url.appendingPathExtension("1")
        if requiredWrite != nil { try inject(.rotationSynchronizeCurrent) }
        let current = try FileHandle(forWritingTo: url)
        do {
            try current.synchronize()
            try current.close()
        } catch {
            try? current.close()
            throw error
        }

        if requiredWrite != nil { try inject(.rotationRemovePrevious) }
        if FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: rotated)
        }
        if requiredWrite != nil { try inject(.rotationMoveCurrent) }
        try FileManager.default.moveItem(at: url, to: rotated)

        if requiredWrite != nil { try inject(.rotationSynchronizeMovedDirectory) }
        try Self.synchronizeDirectory(directory)

        if requiredWrite != nil { try inject(.rotationCreateCurrent) }
        guard FileManager.default.createFile(
            atPath: path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if requiredWrite != nil { try inject(.rotationSynchronizeCreatedDirectory) }
        try Self.synchronizeDirectory(directory)
    }

    private func inject(_ point: FailurePoint) throws {
        if shouldFail(point) { throw POSIXError(.EIO) }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Malformed or torn lines are isolated and skipped; later complete records
    /// remain independently decodable.
    public func entries() throws -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
