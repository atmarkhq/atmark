import Foundation
import Testing

@testable import AtmarkCore

@Suite("Endpoint publication")
struct EndpointTests {
    /// The directory name contains a space on purpose. The real location is
    /// `~/Library/Application Support/Atmark`, and an earlier version of this code
    /// passed `URL.path(percentEncoded: false)` — which percent-encodes — to `FileManager`, so every
    /// write failed there while passing here. Space-free test paths hid it.
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "atmark endpoint \(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "endpoint.json")
    }

    @Test("the published file is mode 0600")
    func fileIsPrivate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Endpoint(port: 51234, token: "secret").write(to: url)

        let mode = try FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        // The file carries the bearer token; group or world read would hand the
        // server to any process running as another user on this machine.
        #expect(mode?.int16Value == 0o600)
    }

    @Test("the containing directory is not world-readable either")
    func directoryIsPrivate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Endpoint(port: 1, token: "t").write(to: url)

        let mode = try FileManager.default
            .attributesOfItem(atPath: url.deletingLastPathComponent().path(percentEncoded: false))[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700)
    }

    @Test("rewriting replaces rather than inheriting the previous mode")
    func rewriteResetsPermissions() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Endpoint(port: 1, token: "first").write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        try Endpoint(port: 2, token: "second").write(to: url)

        let mode = try FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        #expect(try Endpoint.read(from: url).port == 2)
    }

    @Test("round-trips through the file")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let endpoint = Endpoint(port: 51234, host: "127.0.0.1", token: "secret", pid: 4242)
        try endpoint.write(to: url)
        #expect(try Endpoint.read(from: url) == endpoint)
    }

    @Test("the url points at the mcp endpoint")
    func urlShape() {
        #expect(Endpoint(port: 8080, token: "t").url.absoluteString == "http://127.0.0.1:8080/mcp")
    }

    @Test("a missing file says the server is not running, actionably")
    func missingFile() {
        let error = #expect(throws: AtmarkError.self) { try Endpoint.read(from: temporaryURL()) }
        #expect(error?.code == .backendUnavailable)
        #expect(error?.hint.contains("Atmark.app") == true)
    }

    @Test("a malformed file is reported rather than silently ignored")
    func malformedFile() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: url)

        let error = #expect(throws: AtmarkError.self) { try Endpoint.read(from: url) }
        #expect(error?.code == .backendUnavailable)
    }

    @Test("a live pid is not stale")
    func livePidIsFresh() {
        #expect(!Endpoint(port: 1, token: "t").isStale)
    }

    @Test("a dead pid is stale")
    func deadPidIsStale() {
        // A crash or kill -9 leaves the file behind: applicationWillTerminate does
        // not run. Readers must detect that rather than dial a dead port.
        #expect(Endpoint(port: 1, token: "t", pid: 999_998).isStale)
    }

    @Test("removal is idempotent")
    func removeIsIdempotent() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Endpoint(port: 1, token: "t").write(to: url)
        Endpoint.remove(at: url)
        Endpoint.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
