import XCTest
@testable import PeardCore

/// Requirement 11.10 — elapsed-time label thresholds.
final class ElapsedTimeTests: XCTestCase {
    private let now = PeardDate.parse("2026-07-28 12:00:00.000Z")!

    private func label(secondsAgo: TimeInterval) -> String {
        ElapsedTime.label(for: now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testBelowOneMinuteIsNow() {
        XCTAssertEqual(label(secondsAgo: 0), "now")
        XCTAssertEqual(label(secondsAgo: 1), "now")
        XCTAssertEqual(label(secondsAgo: 59), "now")
    }

    func testWholeMinutesBelowAnHour() {
        XCTAssertEqual(label(secondsAgo: 60), "1m")
        XCTAssertEqual(label(secondsAgo: 119), "1m")
        XCTAssertEqual(label(secondsAgo: 120), "2m")
        XCTAssertEqual(label(secondsAgo: 59 * 60), "59m")
        XCTAssertEqual(label(secondsAgo: 60 * 60 - 1), "59m")
    }

    func testWholeHoursBelowADay() {
        XCTAssertEqual(label(secondsAgo: 60 * 60), "1h")
        XCTAssertEqual(label(secondsAgo: 90 * 60), "1h")
        XCTAssertEqual(label(secondsAgo: 23 * 3600), "23h")
        XCTAssertEqual(label(secondsAgo: 24 * 3600 - 1), "23h")
    }

    func testWholeDaysThereafter() {
        XCTAssertEqual(label(secondsAgo: 24 * 3600), "1d")
        XCTAssertEqual(label(secondsAgo: 47 * 3600), "1d")
        XCTAssertEqual(label(secondsAgo: 8 * 24 * 3600), "8d")
        XCTAssertEqual(label(secondsAgo: 365 * 24 * 3600), "365d")
    }

    func testFutureDatesClampToNow() {
        XCTAssertEqual(ElapsedTime.label(for: now.addingTimeInterval(500), now: now), "now")
    }
}

/// Requirement 11.7, 11.8 — partner label derivation and truncation.
final class PartnerLabelTests: XCTestCase {
    func testPrefersDisplayName() {
        XCTAssertEqual(PartnerLabel.resolve(displayName: "Ada", email: "ada@example.com"), "Ada")
    }

    func testFallsBackToEmailLocalPart() {
        XCTAssertEqual(PartnerLabel.resolve(displayName: "", email: "ada@example.com"), "ada")
        XCTAssertEqual(PartnerLabel.resolve(displayName: nil, email: "ada@example.com"), "ada")
    }

    func testFallsBackToPartner() {
        XCTAssertEqual(PartnerLabel.resolve(displayName: "", email: ""), "Partner")
        XCTAssertEqual(PartnerLabel.resolve(displayName: nil, email: nil), "Partner")
        XCTAssertEqual(PartnerLabel.resolve(displayName: nil, email: "@example.com"), "Partner")
    }

    func testResolvesFromUserRecord() {
        XCTAssertEqual(
            PartnerLabel.resolve(user: UserRecord(id: "u", email: "bob@x.io", displayName: nil)),
            "bob"
        )
        XCTAssertEqual(PartnerLabel.resolve(user: nil), "Partner")
    }

    func testTruncatesBeyondEightCharacters() {
        XCTAssertEqual(PartnerLabel.short("Ada"), "Ada")
        XCTAssertEqual(PartnerLabel.short("12345678"), "12345678")
        XCTAssertEqual(PartnerLabel.short("123456789"), "1234567…")
    }

    /// A former member's moments stay in the timeline after they leave, and in a
    /// group there is no "partner" to attribute them to.
    func testUnknownAuthorFallbackIsNotPartner() {
        XCTAssertEqual(PartnerLabel.unknown, "Someone")
        XCTAssertNotEqual(PartnerLabel.unknown, PartnerLabel.fallback)
        XCTAssertEqual(PartnerLabel.short(PartnerLabel.unknown), "Someone")
    }

    func testTruncationCountsCharactersNotBytes() {
        XCTAssertEqual(PartnerLabel.short("🍐🍐🍐🍐🍐🍐🍐🍐🍐"), "🍐🍐🍐🍐🍐🍐🍐…")
    }
}
