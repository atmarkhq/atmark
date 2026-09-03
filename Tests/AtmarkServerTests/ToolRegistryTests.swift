import AtmarkCore
import Testing

@testable import AtmarkServer

@Suite("Tool registry gating")
struct ToolRegistryTests {
    private static let registry = SyntheticToolCatalogue.registry

    private static func names(config: Config, capabilities: Capabilities) -> [String] {
        registry.tools(config: config, capabilities: capabilities).map(\.name)
    }

    private static func config(
        reminders: Config.ModuleConfig = .init(enabled: true, writes: true),
        mail: Config.ModuleConfig = .init(enabled: true, writes: false)
    ) -> Config {
        Config(modules: ["reminders": reminders, "mail": mail])
    }

    // MARK: AC11 — the reason capabilities are a set

    @Test("two tokens with different capability sets see different tool lists")
    func capabilityTiersProduceDifferentLists() {
        let config = Self.config()
        let full = Self.names(config: config, capabilities: .all)
        let readOnly = Self.names(config: config, capabilities: .readOnly)

        #expect(full != readOnly)
        #expect(full.contains("atmark_reminders_create"))
        #expect(full.contains("atmark_reminders_delete"))

        // This is the property batch four's remote token depends on: the
        // prompt-injection blast radius of a web agent must not include
        // destructive tools.
        #expect(!readOnly.contains("atmark_reminders_create"))
        #expect(!readOnly.contains("atmark_reminders_delete"))
        #expect(readOnly.contains("atmark_reminders_search"))
        #expect(readOnly.contains("atmark_status"))
    }

    @Test("adding a second token needs no change to the registry")
    func secondTokenIsPureData() {
        // The store is the only thing that grows. Both identities go through the
        // same lookup and the same registry call.
        let store = TokenStore([
            "local-token": TokenIdentity(label: "local", capabilities: .all),
            "remote-token": TokenIdentity(label: "remote", capabilities: .readOnly),
        ])
        let config = Self.config()

        let local = Self.names(config: config, capabilities: store.identity(for: "local-token")!.capabilities)
        let remote = Self.names(config: config, capabilities: store.identity(for: "remote-token")!.capabilities)

        #expect(local.count > remote.count)
        #expect(Set(remote).isSubset(of: Set(local)))
    }

    // MARK: Module gating

    @Test("a disabled module contributes nothing at all")
    func disabledModuleIsAbsent() {
        let config = Self.config(reminders: .init(enabled: false, writes: true))
        let names = Self.names(config: config, capabilities: .all)

        // Absent, not present-and-erroring: a listed tool keeps costing tokens on
        // every request and keeps inviting the model to call it (A6).
        #expect(!names.contains { $0.hasPrefix("atmark_reminders") })
        #expect(names.contains("atmark_mail_search"))
    }

    @Test("writes off leaves the read-only tools and removes the rest")
    func writesOffHidesMutations() {
        let config = Self.config(reminders: .init(enabled: true, writes: false))
        let names = Self.names(config: config, capabilities: .all)

        #expect(names.contains("atmark_reminders_search"))
        #expect(!names.contains("atmark_reminders_create"))
        #expect(!names.contains("atmark_reminders_delete"))
    }

    @Test("both gates must open — a write token cannot override module config")
    func capabilityDoesNotOverrideConfig() {
        // The token says the caller may write; the config says this module may
        // not be written. Config wins.
        let config = Self.config(reminders: .init(enabled: true, writes: false))
        #expect(!Self.names(config: config, capabilities: .all).contains("atmark_reminders_create"))
    }

    @Test("a module missing from config contributes nothing")
    func unknownModuleIsAbsent() {
        let config = Config(modules: [:])
        #expect(Self.names(config: config, capabilities: .all) == ["atmark_status"])
    }

    @Test("server-level tools are not gated by module config")
    func statusSurvivesEverythingBeingOff() {
        let config = Config(modules: [
            "reminders": .init(enabled: false, writes: false),
            "mail": .init(enabled: false, writes: false),
        ])
        #expect(Self.names(config: config, capabilities: .readOnly) == ["atmark_status"])
    }

    @Test("a caller with no capabilities sees nothing")
    func emptyCapabilitiesSeeNothing() {
        #expect(Self.names(config: Self.config(), capabilities: []).isEmpty)
    }

    @Test("the shipped catalogue exposes exactly one tool")
    func batchOneCatalogue() {
        // Scope guard: module tools belong to the module child tasks, and a stub
        // added here would be indistinguishable from a real one to a client.
        #expect(
            ProductionToolCatalogue.registry
                .tools(config: Self.config(), capabilities: .all)
                .map(\.name) == ["atmark_status"]
        )
    }

    @Test("the tool list is ordered deterministically")
    func stableOrdering() {
        let config = Self.config()
        #expect(Self.names(config: config, capabilities: .all) == Self.names(config: config, capabilities: .all).sorted())
    }
}
