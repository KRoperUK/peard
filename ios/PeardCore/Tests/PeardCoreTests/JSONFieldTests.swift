import XCTest
@testable import PeardCore

/// Request-body encoding.
///
/// These exist because of a real, silent bug: the client could only encode
/// `[String: String]`, so `setMuted` sent `"muted": "true"` — a JSON string — and
/// the mute route, which binds that field to a Go `bool`, answered
/// `400 Invalid request body`. Nothing surfaced in the UI: the toggle simply sprang
/// back. The server had been verified with curl sending a real boolean, so the
/// mismatch was invisible from either side on its own.
final class JSONFieldTests: XCTestCase {
    private func encode(_ fields: [String: JSONField]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }

    func testBoolEncodesUnquoted() throws {
        XCTAssertEqual(
            try encode(["muted": .bool(true)]),
            #"{"muted":true}"#
        )
        XCTAssertEqual(
            try encode(["muted": .bool(false)]),
            #"{"muted":false}"#
        )
    }

    func testStringStaysQuoted() throws {
        XCTAssertEqual(
            try encode(["pair": .string("abc123")]),
            #"{"pair":"abc123"}"#
        )
    }

    /// The shape `setMuted` actually sends.
    func testMutePayload() throws {
        XCTAssertEqual(
            try encode(["pair": .string("abc123"), "muted": .bool(true)]),
            #"{"muted":true,"pair":"abc123"}"#
        )
    }

    func testNumbersEncodeUnquoted() throws {
        XCTAssertEqual(try encode(["page": .int(2)]), #"{"page":2}"#)
        XCTAssertEqual(try encode(["ratio": .double(0.5)]), #"{"ratio":0.5}"#)
    }

    func testNullEncodesAsNull() throws {
        XCTAssertEqual(try encode(["note": .null]), #"{"note":null}"#)
    }

    /// The literal conformances are what keep call sites readable; a `"true"` typo
    /// would otherwise be indistinguishable from `true` at a glance.
    func testLiteralsPickTheRightCase() throws {
        let fields: [String: JSONField] = ["muted": true, "pair": "abc", "page": 3]
        XCTAssertEqual(
            try encode(fields),
            #"{"muted":true,"page":3,"pair":"abc"}"#
        )
    }
}
