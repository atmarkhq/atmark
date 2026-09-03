import Foundation
import Testing

@testable import AtmarkCore

@Suite("JSONValue pruning and timestamps")
struct JSONValueTests {
    @Test("nulls and empties are dropped")
    func dropsEmpties() {
        #expect(JSONValue.null.pruned() == nil)
        #expect(JSONValue.string("").pruned() == nil)
        #expect(JSONValue.array([]).pruned() == nil)
        #expect(JSONValue.object([:]).pruned() == nil)
    }

    @Test("false and zero survive — they are values, not absences")
    func keepsFalsyValues() {
        // The bug this guards against: pruning by falsiness would silently delete
        // `completed: false` from a reminder, which reads as "unknown" instead of
        // "not completed".
        #expect(JSONValue.bool(false).pruned() == .bool(false))
        #expect(JSONValue.int(0).pruned() == .int(0))
        #expect(JSONValue.double(0).pruned() == .double(0))
    }

    @Test("pruning reaches into nested structures")
    func prunesRecursively() {
        let input = JSONValue.object([
            "id": .string("R1"),
            "title": .string("Buy milk"),
            "notes": .null,
            "tags": .array([]),
            "due": .object([:]),
            "completed": .bool(false),
            "list": .object(["name": .string("Inbox"), "colour": .null]),
        ])

        #expect(input.pruned() == .object([
            "id": .string("R1"),
            "title": .string("Buy milk"),
            "completed": .bool(false),
            "list": .object(["name": .string("Inbox")]),
        ]))
    }

    @Test("an object left empty by pruning is itself dropped")
    func collapsesToNothing() {
        let input = JSONValue.object(["a": .null, "b": .object(["c": .string("")])])
        #expect(input.pruned() == nil)
    }

    @Test("nulls inside arrays are removed without leaving holes")
    func prunesInsideArrays() {
        let input = JSONValue.array([.string("a"), .null, .string(""), .int(2)])
        #expect(input.pruned() == .array([.string("a"), .int(2)]))
    }

    @Test("codable round-trip preserves structure")
    func roundTrips() throws {
        let value = JSONValue.object([
            "n": .int(1), "d": .double(1.5), "b": .bool(true),
            "s": .string("x"), "a": .array([.int(1)]), "nul": .null,
        ])
        let decoded = try JSONDecoder().decode(
            JSONValue.self, from: try JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test("timestamps are ISO-8601 with an explicit offset, never locale-formatted")
    func timestampFormat() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .string(let text) = JSONValue.timestamp(date, timeZone: TimeZone(identifier: "Asia/Shanghai")!) else {
            Issue.record("timestamp did not produce a string")
            return
        }
        #expect(text == "2023-11-15T06:13:20+08:00")
    }

    @Test("UTC renders as Z and parses back to the same instant")
    func timestampRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = ISO8601.string(from: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == "2023-11-14T22:13:20Z")
        #expect(ISO8601.date(from: text) == date)
    }

    @Test("fractional seconds are accepted on input though never emitted")
    func acceptsFractionalSecondsOnInput() {
        #expect(ISO8601.date(from: "2023-11-15T22:13:20.500Z") != nil)
    }

    @Test("a locale-formatted date is rejected rather than guessed at")
    func rejectsNonISOInput() {
        #expect(ISO8601.date(from: "November 15, 2023") == nil)
    }
}
