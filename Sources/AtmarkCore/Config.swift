import Foundation

/// On-disk configuration, at `~/Library/Application Support/Atmark/config.json`.
///
/// Edited by the Settings window, and by hand. A change re-derives the tool
/// registry, so the shape here is the shape the tool surface is a function of.
public struct Config: Codable, Hashable, Sendable {
    public var modules: [String: ModuleConfig]
    public var escapeHatch: EscapeHatchConfig
    public var http: HTTPConfig

    public init(
        modules: [String: ModuleConfig] = Config.defaultModules,
        escapeHatch: EscapeHatchConfig = .init(),
        http: HTTPConfig = .init()
    ) {
        self.modules = modules
        self.escapeHatch = escapeHatch
        self.http = http
    }

    private enum CodingKeys: String, CodingKey {
        case modules
        case escapeHatch = "escape_hatch"
        case http
    }

    public static let defaultModules: [String: ModuleConfig] = [
        "reminders": ModuleConfig(enabled: true, writes: false),
        "mail": ModuleConfig(enabled: true, writes: false),
    ]

    /// A module contributes tools only when enabled, and contributes its
    /// write tools only when `writes` is on. Both default conservatively:
    /// writes are off until the user turns them on.
    public struct ModuleConfig: Codable, Hashable, Sendable {
        public var enabled: Bool
        public var writes: Bool

        public init(enabled: Bool = false, writes: Bool = false) {
            self.enabled = enabled
            self.writes = writes
        }
    }

    /// Reserved for the generic AppleScript escape hatch (batch three). Present
    /// so the config file does not change shape when it lands; off, with an empty
    /// allowlist, until then.
    public struct EscapeHatchConfig: Codable, Hashable, Sendable {
        public var enabled: Bool
        public var allowedApps: [String]

        public init(enabled: Bool = false, allowedApps: [String] = []) {
            self.enabled = enabled
            self.allowedApps = allowedApps
        }

        private enum CodingKeys: String, CodingKey {
            case enabled
            case allowedApps = "allowed_apps"
        }
    }

    public struct HTTPConfig: Codable, Hashable, Sendable {
        /// `0` binds an ephemeral port; whatever is actually bound is published
        /// to `endpoint.json`.
        public var port: Int
        public var bind: String

        public init(port: Int = 0, bind: String = "127.0.0.1") {
            self.port = port
            self.bind = bind
        }
    }
}

// MARK: - Validation

extension Config {
    /// Rejects a configuration that would widen the trust boundary.
    ///
    /// Constraint C1 — loopback only — is enforced here rather than left to
    /// convention, because the failure mode is a listener silently reachable from
    /// the local network with a bearer token as the only thing in the way.
    public func validate() throws {
        guard Config.isLoopback(http.bind) else {
            throw AtmarkError(
                .invalidArgument,
                detail: "http.bind",
                hint: "Atmark binds loopback only. Use 127.0.0.1 or ::1."
            )
        }
        guard (0...65535).contains(http.port) else {
            throw AtmarkError(
                .invalidArgument,
                detail: "http.port",
                hint: "Use a port between 0 and 65535. 0 selects an ephemeral port."
            )
        }
    }

    /// True for a literal loopback address, and only for one.
    ///
    /// Hostnames are rejected on purpose, `localhost` included: what a name
    /// resolves to is not ours to control, and the whole point of this check is
    /// that the bind address cannot be pointed elsewhere.
    public static func isLoopback(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            // 127.0.0.0/8, per RFC 1122. s_addr is network byte order.
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { raw in
                raw.enumerated().allSatisfy { index, byte in
                    byte == (index == raw.count - 1 ? 1 : 0)
                }
            }
        }
        return false
    }
}

// MARK: - Persistence

extension Config {
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Atmark", directoryHint: .isDirectory)
    }

    public static var defaultURL: URL {
        defaultDirectory.appending(path: "config.json")
    }

    /// Loads configuration, falling back to defaults when the file does not exist
    /// yet. A file that exists but does not parse is an error rather than a
    /// silent reset — quietly discarding the user's settings, and with them their
    /// write gates, is the wrong way to fail.
    public static func load(from url: URL = Config.defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return Config()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AtmarkError(
                .backendUnavailable,
                detail: "config.json",
                hint: "Could not read \(url.path(percentEncoded: false)). Check file permissions."
            )
        }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw AtmarkError(
                .invalidArgument,
                detail: "config.json",
                hint: "\(url.path(percentEncoded: false)) is not valid Atmark configuration. Fix or delete it to restore defaults."
            )
        }
        try config.validate()
        return config
    }

    /// Validates before writing, so an invalid configuration cannot be persisted
    /// and then loaded at next launch.
    public func save(to url: URL = Config.defaultURL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
