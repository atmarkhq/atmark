import Foundation
import Testing

@Suite("AtmarkApp source import boundaries")
struct SourceImportBoundaryTests {
    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/AtmarkApp")
    }

    private static func importedModule(in line: String) -> String? {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first.hasPrefix("@") {
            tokens.removeFirst()
        }
        guard tokens.first == "import", tokens.count >= 2 else { return nil }

        let declarationKinds: Set<String> = [
            "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
        ]
        let moduleToken = declarationKinds.contains(tokens[1]) && tokens.count >= 3
            ? tokens[2]
            : tokens[1]
        return moduleToken.split(separator: ".").first.map(String.init)
    }

    private static func importedModules(in directoryName: String) throws -> [(String, Int, String)] {
        let directory = sourceDirectory.appending(path: directoryName)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }

        #expect(!files.isEmpty, "found no Swift sources under AtmarkApp/\(directoryName)")

        return try files.flatMap { file in
            let contents = try String(
                contentsOf: directory.appending(path: file),
                encoding: .utf8
            )
            return contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { offset, line in
                    importedModule(in: String(line)).map { (file, offset + 1, $0) }
                }
        }
    }

    @Test("Runtime does not import SwiftUI")
    func runtimeStaysIndependentOfSwiftUI() throws {
        for (file, line, module) in try Self.importedModules(in: "Runtime") {
            #expect(
                module != "SwiftUI",
                "Runtime/\(file):\(line) imports SwiftUI"
            )
        }
    }

    @Test("app shell and presentation surfaces do not import backend frameworks")
    func appShellAndPresentationSurfacesStayIndependentOfBackendFrameworks() throws {
        let forbidden: Set<String> = ["EventKit", "Carbon", "MCP"]

        for directory in ["App", "Presentation", "MenuBar", "Settings", "SharedUI", "PreviewSupport"] {
            for (file, line, module) in try Self.importedModules(in: directory) {
                #expect(
                    !forbidden.contains(module) && !module.hasPrefix("NIO"),
                    "\(directory)/\(file):\(line) imports backend framework \(module)"
                )
            }
        }
    }
}
