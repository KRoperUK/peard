import XCTest
@testable import PeardCore

/// Requirement 5.8 — a user-supplied value cannot change the filter structure.
final class PeardFilterTests: XCTestCase {
    func testPlainValueIsUnchanged() {
        XCTAssertEqual(PeardFilter.equals("user", "abc123"), #"user = "abc123""#)
    }

    func testDoubleQuotesAreEscaped() {
        XCTAssertEqual(
            PeardFilter.equals("user", #"ab"cd"#),
            #"user = "ab\"cd""#
        )
    }

    func testBackslashesAreEscapedBeforeQuotes() {
        XCTAssertEqual(PeardFilter.escaped(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(PeardFilter.escaped(#"a\"b"#), #"a\\\"b"#)
    }

    func testInjectionAttemptStaysInsideTheLiteral() {
        let hostile = #"x" || id != ""#
        let filter = PeardFilter.equals("user", hostile)

        XCTAssertEqual(filter, #"user = "x\" || id != \"""#)
        // Exactly two unescaped quotes remain: the ones we added.
        XCTAssertEqual(unescapedQuoteCount(in: filter), 2)
    }

    func testControlCharactersAreRemoved() {
        XCTAssertEqual(PeardFilter.escaped("a\nb\tc\u{0}d"), "abcd")
        XCTAssertEqual(unescapedQuoteCount(in: PeardFilter.equals("user", "a\nb")), 2)
    }

    func testEmojiAndNonASCIISurvive() {
        XCTAssertEqual(PeardFilter.escaped("Adá 🍐"), "Adá 🍐")
    }

    func testAndJoinsNonEmptyClauses() {
        XCTAssertEqual(
            PeardFilter.and(PeardFilter.equals("pair", "p1"), PeardFilter.equals("type", "event")),
            #"pair = "p1" && type = "event""#
        )
        XCTAssertEqual(PeardFilter.and(["", #"a = "b""#, ""]), #"a = "b""#)
    }

    func testNotEqualsEscapesToo() {
        XCTAssertEqual(PeardFilter.notEquals("user", #"a"b"#), #"user != "a\"b""#)
    }

    /// Counts quotes that are not preceded by an escaping backslash.
    private func unescapedQuoteCount(in string: String) -> Int {
        var count = 0
        var escaped = false
        for character in string {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "\"" {
                count += 1
            }
        }
        return count
    }
}
