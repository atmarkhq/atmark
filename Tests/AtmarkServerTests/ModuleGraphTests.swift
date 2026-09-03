import Testing

@testable import AtmarkServer

/// Step 1 owns the package graph and nothing else. This asserts the graph links:
/// `AtmarkServer` resolves against `AtmarkCore`, `AtmarkModules`, the MCP SDK, and
/// swift-nio. Real server behaviour arrives in steps 4–6.
@Suite("Package graph")
struct ModuleGraphTests {
    @Test("AtmarkServer links its dependencies")
    func serverNamespaceExists() {
        #expect(AtmarkServer.self == AtmarkServer.self)
    }
}
