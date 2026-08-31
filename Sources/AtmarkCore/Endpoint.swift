import Foundation

/// What the shim needs to reach the resident server: where it is, and the token
/// to present.
///
/// Written to `~/Library/Application Support/Atmark/endpoint.json` at mode 0600.
/// Storing the token in a file rather than the Keychain is deliberate: a separate
/// binary reading a Keychain item triggers its own authorization prompts, and the
/// file already sits inside the user's own home directory on a single-user
/// machine. Recorded as an accepted tradeoff.
public struct Endpoint: Codable, Hashable, Sendable {
    public let port: Int
    public let host: String
    public let token: String
    /// Stamped so a stale file from a crashed instance is recognisable.
    public let pid: Int32

    public init(port: Int, host: String = "127.0.0.1", token: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.port = port
        self.host = host
        self.token = token
        self.pid = pid
    }

    public var url: URL {
        URL(string: "http://\(host):\(port)/mcp")!
    }

    public static var defaultURL: URL {
        Config.defaultDirectory.appending(path: "endpoint.json")
    }
}

extension Endpoint {
    /// Writes the file, creating it 0600 *before* the token is in it.
    ///
    /// The order matters. Writing then chmod-ing leaves a window in which the
    /// token is world-readable, which is exactly the kind of gap that only ever
    /// shows up in someone else's incident report.
    public func write(to url: URL = Endpoint.defaultURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Replace rather than truncate, so a reader never sees a half-written file
        // and never inherits permissions from a previous run.
        if manager.fileExists(atPath: url.path(percentEncoded: false)) {
            try manager.removeItem(at: url)
        }
        guard manager.createFile(
            atPath: url.path(percentEncoded: false),
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AtmarkError(
                .backendUnavailable,
                detail: "endpoint.json",
                hint: "Could not create \(url.path(percentEncoded: false)). Check permissions on the Atmark support directory."
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)

        // Belt and braces: confirm what we actually got, since a pre-existing
        // umask or a filesystem that ignores the attribute would fail silently.
        let mode = try manager.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        guard mode?.int16Value == 0o600 else {
            try? manager.removeItem(at: url)
            throw AtmarkError(
                .backendUnavailable,
                detail: "endpoint.json",
                hint: "Refusing to publish the bearer token in a file that is not mode 0600."
            )
        }
    }

    public static func read(from url: URL = Endpoint.defaultURL) throws -> Endpoint {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw AtmarkError(
                .backendUnavailable,
                detail: "endpoint.json",
                hint: "Atmark does not appear to be running. Launch Atmark.app and retry."
            )
        }
        do {
            return try JSONDecoder().decode(Endpoint.self, from: try Data(contentsOf: url))
        } catch {
            throw AtmarkError(
                .backendUnavailable,
                detail: "endpoint.json",
                hint: "\(url.path(percentEncoded: false)) is unreadable or malformed. Quit and relaunch Atmark.app to republish it."
            )
        }
    }

    /// Whether the process that published this file is still alive.
    ///
    /// The file is removed on a normal quit, but not on a crash or a `kill -9` —
    /// `applicationWillTerminate` simply does not run then. So a reader must treat
    /// the file as a hint rather than a fact, which is what the `pid` is for. The
    /// alternative, connecting to a dead port and waiting, is exactly the hang
    /// this avoids.
    public var isStale: Bool {
        // Signal 0 performs the permission and existence checks without signalling.
        kill(pid, 0) != 0 && errno == ESRCH
    }

    public static func remove(at url: URL = Endpoint.defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
