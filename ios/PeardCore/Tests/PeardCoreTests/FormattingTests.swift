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

    // MARK: Spoken age

    private func spoken(hoursAgo: Double) -> String? {
        ElapsedTime.spokenAge(for: now.addingTimeInterval(-hoursAgo * 3600), now: now)
    }

    /// "now ago" was what VoiceOver used to say.
    func testSpokenAgeWithinTheHourIsAPhraseNotNow() {
        XCTAssertEqual(spoken(hoursAgo: 0), "in the last hour")
        XCTAssertEqual(spoken(hoursAgo: 0.9), "in the last hour")
    }

    func testSpokenAgeSaysItsUnitsInFullAndPluralises() {
        XCTAssertEqual(spoken(hoursAgo: 1), "1 hour ago")
        XCTAssertEqual(spoken(hoursAgo: 3), "3 hours ago")
        XCTAssertEqual(spoken(hoursAgo: 24), "1 day ago")
        XCTAssertEqual(spoken(hoursAgo: 24 * 14), "2 weeks ago")
        XCTAssertEqual(spoken(hoursAgo: 24 * 120), "4 months ago")
        XCTAssertEqual(spoken(hoursAgo: 24 * 400), "1 year ago")
    }

    /// Heard and seen agree: every threshold the tile uses, the voice uses.
    func testSpokenAgeChangesUnitWhereTheTileDoes() {
        let day: Double = 24
        let samples: [Double] = [0.5, 1, 23, day, day * 6.9, day * 7, day * 59, day * 60, day * 364, day * 366]
        let words: [String: String] = [
            "now": "in the last hour", "h": "hour", "d": "day", "w": "week", "mo": "month", "y": "year",
        ]
        for hours in samples {
            let date = now.addingTimeInterval(-hours * 3600)
            let tile = ElapsedTime.age(for: date, now: now)!
            let voice = ElapsedTime.spokenAge(for: date, now: now)!
            let tileUnit = tile.drop(while: { $0.isNumber })
            let expected = words[String(tileUnit)]!
            XCTAssertTrue(voice.contains(expected), "\(hours)h: tile \(tile), voice \(voice)")
        }
    }

    func testNoDateSaysNothing() {
        XCTAssertNil(ElapsedTime.spokenAge(for: nil, now: now))
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
