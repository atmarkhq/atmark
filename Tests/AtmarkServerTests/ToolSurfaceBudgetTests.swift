import Foundation
import MCP
import AtmarkCore
import Testing

@testable import AtmarkServer

@Suite("Production tool-surface budget")
struct ToolSurfaceBudgetTests {
    private static let batchOneByteLimit = 6 * 1024
    private static let descriptionCharacterLimit = 200
    private static let longTermToolCountLimit = 40

    private var tools: [Tool] {
        var config = Config()
        for module in ProductionToolCatalogue.definitions.compactMap(\.module) {
            config.modules[module] = .init(enabled: true, writes: true)
        }
        return ProductionToolCatalogue.registry.tools(config: config, capabilities: .all)
    }

    @Test("serialized tools/list stays within the batch-one budget")
    func serializedListFitsBudget() throws {
        let response = ListTools.response(id: 1, result: ListTools.Result(tools: tools))
        let bytes = try JSONEncoder().encode(response).count

        #expect(
            bytes <= Self.batchOneByteLimit,
            "tools/list is \(bytes) bytes; the batch-one limit is \(Self.batchOneByteLimit)"
        )
    }

    @Test("every description stays terse")
    func descriptionsFitBudget() {
        for tool in tools {
            let count = tool.description?.count ?? 0
            #expect(
                count <= Self.descriptionCharacterLimit,
                "\(tool.name) has a \(count)-character description; the limit is \(Self.descriptionCharacterLimit)"
            )
        }
    }

    @Test("the catalogue stays below the long-term tool-count ceiling")
    func toolCountFitsBudget() {
        #expect(
            tools.count <= Self.longTermToolCountLimit,
            "catalogue has \(tools.count) tools; the long-term limit is \(Self.longTermToolCountLimit)"
        )
    }
}
