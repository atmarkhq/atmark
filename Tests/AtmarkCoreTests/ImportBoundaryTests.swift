import Foundation
import Testing

@testable import AtmarkCore

/// `AtmarkCore` must stay free of UI and transport imports so the safety model is
/// testable without a GUI, a running server, or a TCC grant.
///
/// The package graph already makes MCP and NIO unreachable from this target —
/// they are not declared dependencies. SwiftUI and AppKit are system frameworks
/// and importable from anywhere, so only a source check can hold that line. They
/// are all listed here anyway: the graph enforces intent silently, this test
/// states it.
@Suite("AtmarkCore import boundary")
struct ImportBoundaryTests {
    private static let forbidden: Set<String> = [
        "SwiftUI", "AppKit", "Cocoa", "MCP",
        "NIO", "NIOCore", "NIOPosix", "NIOHTTP1",
    ]

    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)      // .../Tests/AtmarkCoreTests/ImportBoundaryTests.swift
            .deletingLastPathComponent()     // .../Tests/AtmarkCoreTests
            .deletingLastPathComponent()     // .../Tests
            .deletingLastPathComponent()     // package root
            .appending(path: "Sources/AtmarkCore")
    }

    /// The module name an `import` line brings in, or `nil` if the line is not an
    /// import. Tolerates leading attributes (`@preconcurrency import X`) and
    /// declaration-kind imports (`import struct Foundation.Data`).
    private static func importedModule(in line: String) -> String? {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first.hasPrefix("@") {
            tokens.removeFirst()
        }
        guard tokens.first == "import", tokens.count >= 2 else { return nil }
        var rest = tokens[1]
        let declarationKinds: Set<String> = [
            "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
        ]
        if declarationKinds.contains(rest), tokens.count >= 3 {
            rest = tokens[2]
        }
        return rest.split(separator: ".").first.map(String.init)
    }

    @Test("no UI or transport imports in AtmarkCore sources")
    func coreImportsStayClean() throws {
        let directory = Self.sourceDirectory
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }

        #expect(!files.isEmpty, "found no sources under \(directory.path(percentEncoded: false)) — the test is not looking where it thinks")

        for file in files {
            let contents = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let module = Self.importedModule(in: String(line)) else { continue }
                #expect(
                    !Self.forbidden.contains(module),
                    "AtmarkCore/\(file):\(offset + 1) imports \(module); the core must stay free of UI and transport imports"
                )
            }
        }
    }

    @Test("the boundary check recognises the import forms it must catch")
    func importParsingCoversRealForms() {
        #expect(Self.importedModule(in: "import SwiftUI") == "SwiftUI")
        #expect(Self.importedModule(in: "  @preconcurrency import AppKit") == "AppKit")
        #expect(Self.importedModule(in: "import struct Foundation.Data") == "Foundation")
        #expect(Self.importedModule(in: "@testable import MCP") == "MCP")
        #expect(Self.importedModule(in: "// import SwiftUI") == nil)
        #expect(Self.importedModule(in: "let importantThing = 1") == nil)
    }
}
