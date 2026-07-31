import XCTest
@testable import PeardCore

/// The values checked here have a Go-side twin in
/// server/internal/contacts/contacts_test.go and were cross-checked once by
/// hand against the server's actual output (see the commit that added this
/// file) — the one property no unit test on either side alone can prove is
/// that the two languages produce the same byte for byte hash.
final class ContactHashingTests: XCTestCase {
    func testEmailIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(ContactHashing.hashEmail(" Alex@Example.com "), ContactHashing.hashEmail("alex@example.com"))
    }

    func testPhoneIgnoresFormatting() {
        XCTAssertEqual(ContactHashing.hashPhone("+44 (7888) 291-038"), ContactHashing.hashPhone("447888291038"))
    }

    func testPhoneIgnoresNonASCIIDigits() {
        // Arabic-indic digits are `Character.isNumber` but not ASCII '0'-'9' —
        // normalisePhone must not treat them as digits, or it would silently
        // diverge from the Go implementation's byte-range check.
        XCTAssertEqual(ContactHashing.normalisePhone("٤٤٧٨٨٨"), "")
    }

    func testEmptyInputHashesToNil() {
        XCTAssertNil(ContactHashing.hashEmail(""))
        XCTAssertNil(ContactHashing.hashPhone(""))
        XCTAssertNil(ContactHashing.hashPhone("   "))
    }

    func testKnownVectorsMatchTheServer() {
        // Printed by both a scratch Swift script and
        // `go test ./internal/contacts -run TestPrintGoldenHashes` during
        // development; pinned here so a future change to either side's
        // normalisation shows up as a failing test instead of a silent
        // mismatch.
        XCTAssertEqual(
            ContactHashing.hashEmail(" Alex@Example.com "),
            "eac91883007ac027a3f3cc5e85ace4856ae237f54f9711ee37e8319337cb8c73"
        )
        XCTAssertEqual(
            ContactHashing.hashPhone("+44 (7888) 291-038"),
            "2514e66b85621dfff0fa9d11909ba8331ba382cec7edb7f0fe7f6e9460d9daa4"
        )
    }
}
