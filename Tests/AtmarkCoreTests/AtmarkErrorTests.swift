import Foundation
import Testing

@testable import AtmarkCore

@Suite("AtmarkError")
struct AtmarkErrorTests {
    @Test("every code carries a non-empty, actionable hint")
    func everyCodeHasHint() {
        for code in AtmarkError.Code.allCases {
            #expect(!code.hint.isEmpty, "\(code.rawValue) has no hint")
            // The hint exists to tell a human what to do; a bare restatement of
            // the code would satisfy "non-empty" while being useless.
            #expect(code.hint.count > 20, "\(code.rawValue) hint looks like a placeholder")
        }
    }

    @Test("the documented code set is exactly what ships")
    func codeSetMatchesDesign() {
        let expected: Set<String> = [
            "permission_denied", "backend_unavailable", "app_not_running", "timeout",
            "not_found", "invalid_argument", "confirmation_required",
            "confirmation_invalid", "writes_disabled", "sync_pending",
        ]
        #expect(Set(AtmarkError.Code.allCases.map(\.rawValue)) == expected)
    }

    @Test("wire form matches the design's shape")
    func wireShape() throws {
        let error = AtmarkError(
            .backendUnavailable,
            detail: "envelope_index",
            hint: "grant Full Disk Access to Atmark.app"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(error), as: UTF8.self)

        #expect(json == #"{"error":{"code":"backend_unavailable","detail":"envelope_index","hint":"grant Full Disk Access to Atmark.app"}}"#)
    }

    @Test("an absent detail is pruned, not emitted as null")
    func detailIsPruned() throws {
        let json = String(decoding: try JSONEncoder().encode(AtmarkError(.timeout)), as: UTF8.self)
        #expect(!json.contains("null"))
        #expect(!json.contains("detail"))
    }

    @Test("the hint defaults to the code's when not overridden")
    func hintDefaults() {
        #expect(AtmarkError(.writesDisabled).hint == AtmarkError.Code.writesDisabled.hint)
    }

    @Test("decoding restores the value, filling in a missing hint")
    func decodes() throws {
        let data = Data(#"{"error":{"code":"not_found"}}"#.utf8)
        let error = try JSONDecoder().decode(AtmarkError.self, from: data)
        #expect(error.code == .notFound)
        #expect(error.detail == nil)
        #expect(error.hint == AtmarkError.Code.notFound.hint)
    }

    @Test("round-trips through its own wire form")
    func roundTrips() throws {
        let original = AtmarkError(.syncPending, detail: "reminder:ABC")
        let decoded = try JSONDecoder().decode(
            AtmarkError.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
