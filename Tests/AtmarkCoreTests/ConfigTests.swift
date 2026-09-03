import Foundation
import Testing

@testable import AtmarkCore

@Suite("Config")
struct ConfigTests {
    // MARK: Loopback enforcement (constraint C1)

    @Test("literal loopback addresses are accepted", arguments: [
        "127.0.0.1", "127.0.0.53", "127.1.2.3", "::1", "0:0:0:0:0:0:0:1",
    ])
    func acceptsLoopback(address: String) {
        #expect(Config.isLoopback(address))
    }

    @Test("everything else is refused", arguments: [
        "0.0.0.0",        // binds every interface — the exact mistake C1 exists to stop
        "192.168.1.10",
        "10.0.0.1",
        "8.8.8.8",
        "::",
        "2001:db8::1",
        "",
        "not-an-address",
        "127.0.0.1:8080", // an address with a port is not an address
    ])
    func refusesNonLoopback(address: String) {
        #expect(!Config.isLoopback(address))
    }

    @Test("hostnames are refused even when they usually resolve to loopback")
    func refusesLocalhostHostname() {
        // What a name resolves to is not ours to control, and the point of the
        // check is that the bind address cannot be pointed elsewhere.
        #expect(!Config.isLoopback("localhost"))
    }

    @Test("validate rejects a non-loopback bind with an actionable hint")
    func validateRejectsBind() {
        var config = Config()
        config.http.bind = "0.0.0.0"
        let error = #expect(throws: AtmarkError.self) { try config.validate() }
        #expect(error?.code == .invalidArgument)
        #expect(error?.detail == "http.bind")
        #expect(error?.hint.contains("127.0.0.1") == true)
    }

    @Test("validate rejects an out-of-range port", arguments: [-1, 65536, 999_999])
    func validateRejectsPort(port: Int) {
        var config = Config()
        config.http.port = port
        let error = #expect(throws: AtmarkError.self) { try config.validate() }
        #expect(error?.code == .invalidArgument)
        #expect(error?.detail == "http.port")
    }

    @Test("port 0 is valid — it means ephemeral")
    func acceptsEphemeralPort() throws {
        var config = Config()
        config.http.port = 0
        try config.validate()
    }

    // MARK: Defaults

    @Test("writes are off by default in every shipped module")
    func writesDefaultOff() {
        let config = Config()
        #expect(!config.modules.isEmpty)
        for (name, module) in config.modules {
            #expect(!module.writes, "module \(name) ships with writes enabled")
        }
    }

    @Test("the escape hatch ships disabled with an empty allowlist")
    func escapeHatchDefaultsClosed() {
        let config = Config()
        #expect(!config.escapeHatch.enabled)
        #expect(config.escapeHatch.allowedApps.isEmpty)
    }

    // MARK: Persistence

    /// Contains a space deliberately — see the note in EndpointTests. The real
    /// config lives under "Application Support".
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "atmark tests \(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "config.json")
    }

    @Test("a missing file yields defaults rather than an error")
    func loadMissingFileUsesDefaults() throws {
        let config = try Config.load(from: temporaryURL())
        #expect(config.http.bind == "127.0.0.1")
        #expect(config.http.port == 0)
    }

    @Test("save then load round-trips, creating the directory")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var original = Config()
        original.modules["reminders"] = .init(enabled: true, writes: true)
        original.http.port = 51_234
        try original.save(to: url)

        let loaded = try Config.load(from: url)
        #expect(loaded == original)
        #expect(loaded.modules["reminders"]?.writes == true)
    }

    @Test("the on-disk keys are snake_case as documented")
    func wireKeysAreSnakeCase() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Config().save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"escape_hatch\""))
        #expect(text.contains("\"allowed_apps\""))
    }

    @Test("a corrupt file is an error, not a silent reset to defaults")
    func corruptFileThrows() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json".utf8).write(to: url)

        // Silently discarding the file would also discard the user's write gates,
        // turning a typo into a permissions change.
        let error = #expect(throws: AtmarkError.self) { try Config.load(from: url) }
        #expect(error?.code == .invalidArgument)
    }

    @Test("a file that binds a routable address is refused on load")
    func loadValidatesBind() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"modules":{},"escape_hatch":{"enabled":false,"allowed_apps":[]},"http":{"port":0,"bind":"0.0.0.0"}}"#.utf8)
            .write(to: url)

        let error = #expect(throws: AtmarkError.self) { try Config.load(from: url) }
        #expect(error?.detail == "http.bind")
    }

    @Test("an invalid configuration cannot be written to disk")
    func saveValidatesFirst() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = Config()
        config.http.bind = "0.0.0.0"

        #expect(throws: AtmarkError.self) { try config.save(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
