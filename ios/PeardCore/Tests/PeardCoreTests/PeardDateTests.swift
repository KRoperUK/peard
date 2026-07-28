import XCTest
@testable import PeardCore

/// Requirement 4.9, 4.10 — PocketBase date coding round-trips.
final class PeardDateTests: XCTestCase {
    func testParsesCanonicalFormatInUTC() throws {
        let date = try XCTUnwrap(PeardDate.parse("2026-07-28 21:30:15.250Z"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PeardDate.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 28)
        XCTAssertEqual(parts.hour, 21)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.second, 15)
    }

    func testParsesVariantWithoutMilliseconds() throws {
        let withMs = try XCTUnwrap(PeardDate.parse("2026-07-28 21:30:15.000Z"))
        let withoutMs = try XCTUnwrap(PeardDate.parse("2026-07-28 21:30:15Z"))
        XCTAssertEqual(withMs, withoutMs)
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(PeardDate.parse(""))
        XCTAssertNil(PeardDate.parse("not a date"))
        XCTAssertNil(PeardDate.parse("2026-07-28T21:30:15Z"))
    }

    /// format → parse → format is a fixed point for every representable value.
    func testFormatParseFormatRoundTrip() throws {
        let samples = [
            "2026-07-28 21:30:15.250Z",
            "1970-01-01 00:00:00.000Z",
            "2000-02-29 12:00:00.001Z",
            "2038-01-19 03:14:07.999Z",
            "2026-12-31 23:59:59.999Z",
        ]
        for sample in samples {
            let parsed = try XCTUnwrap(PeardDate.parse(sample), sample)
            XCTAssertEqual(PeardDate.format(parsed), sample)
            let reparsed = try XCTUnwrap(PeardDate.parse(PeardDate.format(parsed)))
            XCTAssertEqual(PeardDate.format(reparsed), sample)
        }
    }

    /// parse → format → parse is a fixed point for arbitrary Dates once
    /// truncated to the precision the format can express.
    func testDateRoundTripAtMillisecondPrecision() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let interval = Double.random(in: 0...4_000_000_000, using: &generator)
            let original = PeardDate.truncatedToMilliseconds(Date(timeIntervalSince1970: interval))
            let round = try XCTUnwrap(PeardDate.parse(PeardDate.format(original)))
            XCTAssertEqual(round.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.0005)
        }
    }

    func testDecoderAndEncoderStrategies() throws {
        struct Wrapper: Codable, Equatable { let created: Date }

        let json = Data(#"{"created":"2026-07-28 21:30:15.250Z"}"#.utf8)
        let decoded = try JSONDecoder.peard.decode(Wrapper.self, from: json)
        let encoded = try JSONEncoder.peard.encode(decoded)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"created":"2026-07-28 21:30:15.250Z"}"#)
    }

    func testDecoderRejectsUnknownFormat() {
        struct Wrapper: Codable { let created: Date }
        let json = Data(#"{"created":"yesterday"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.peard.decode(Wrapper.self, from: json))
    }
}
