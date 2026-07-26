import Testing
import Foundation
@testable import ResticStationCore

@Suite("restic dual-format ISO8601 date decoding")
struct DateDecodingTests {
    private struct Wrapper: Decodable {
        let d: Date
    }

    @Test("fractional seconds with timezone offset (microseconds)")
    func fractionalMicroseconds() throws {
        let json = #"{"d":"2026-07-26T16:57:04.634751-04:00"}"#
        let value = try makeResticJSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        // 16:57:04.634751-04:00 == 20:57:04.634751 UTC
        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 26
        expected.hour = 20; expected.minute = 57; expected.second = 4
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expectedDate = utc.date(from: expected)!
        #expect(abs(value.d.timeIntervalSince(expectedDate) - 0.634751) < 0.000_01)
    }

    @Test("fractional seconds with nanosecond precision")
    func fractionalNanoseconds() throws {
        // restic's `ls` mtime carries 9 fractional digits.
        let json = #"{"d":"2026-07-26T16:57:01.494355014-04:00"}"#
        let value = try makeResticJSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        var base = DateComponents()
        base.year = 2026; base.month = 7; base.day = 26
        base.hour = 20; base.minute = 57; base.second = 1
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let baseDate = utc.date(from: base)!
        #expect(abs(value.d.timeIntervalSince(baseDate) - 0.494355014) < 0.000_001)
    }

    @Test("whole seconds, no fractional part")
    func wholeSeconds() throws {
        let json = #"{"d":"2026-07-26T16:57:04-04:00"}"#
        let value = try makeResticJSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 26
        expected.hour = 20; expected.minute = 57; expected.second = 4
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expectedDate = utc.date(from: expected)!
        #expect(value.d == expectedDate)
    }

    @Test("Zulu (UTC) suffix, no fractional part")
    func zuluWholeSeconds() throws {
        let json = #"{"d":"2026-07-26T20:57:04Z"}"#
        let value = try makeResticJSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 26
        expected.hour = 20; expected.minute = 57; expected.second = 4
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expectedDate = utc.date(from: expected)!
        #expect(value.d == expectedDate)
    }

    @Test("invalid date string throws, does not crash")
    func invalidDate() {
        let json = #"{"d":"not-a-date"}"#
        #expect(throws: (any Error).self) {
            try makeResticJSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        }
    }
}
