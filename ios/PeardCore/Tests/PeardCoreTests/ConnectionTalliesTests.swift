import XCTest
@testable import PeardCore

/// `GET /api/peard/tallies` decoding, and the merge of locally queued sends that
/// the server has not seen yet.
final class ConnectionTalliesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ string: String) -> Date {
        PeardDate.parse(string)!
    }

    private func decode(_ json: String) throws -> ConnectionTallies {
        try JSONDecoder.peard.decode(ConnectionTallies.self, from: Data(json.utf8))
    }

    func testDecodesBothSidesAndPerKindCounts() throws {
        let tallies = try decode("""
        {
          "pair": "p1",
          "mine":   { "day": 6, "week": 14, "month": 14, "all": 14 },
          "others": { "day": 0, "week": 2,  "month": 2,  "all": 2 },
          "kinds": [
            { "kind": "beer", "emoji": "🍺", "label": "Beer",
              "mine":   { "day": 2, "week": 4, "month": 4, "all": 4 },
              "others": { "day": 0, "week": 1, "month": 1, "all": 1 } },
            { "kind": "loo", "emoji": "💩", "label": "Loo",
              "mine":   { "day": 1, "week": 5, "month": 5, "all": 5 },
              "others": { "day": 0, "week": 0, "month": 0, "all": 0 } }
          ]
        }
        """)

        XCTAssertEqual(tallies.pair, "p1")
        XCTAssertEqual(tallies.mine, TallyPeriods(day: 6, week: 14, month: 14, all: 14))
        XCTAssertEqual(tallies.others, TallyPeriods(day: 0, week: 2, month: 2, all: 2))
        XCTAssertEqual(tallies.kinds.count, 2)
        XCTAssertEqual(tallies.kinds[0].kind, .beer)
        XCTAssertEqual(tallies.kinds[0].total, 5)
        XCTAssertEqual(tallies.kinds[1].total, 5)
    }

    /// A connection where nobody else has logged anything omits `others`, and a
    /// server that predates per-kind detail omits `kinds`. Neither is an error.
    func testMissingSectionsDecodeAsZero() throws {
        let tallies = try decode("""
        { "pair": "p1", "mine": { "day": 1, "week": 1, "month": 1, "all": 1 } }
        """)

        XCTAssertEqual(tallies.others, .zero)
        XCTAssertTrue(tallies.kinds.isEmpty)
        XCTAssertEqual(tallies.mine.all, 1)
    }

    /// An unknown kind still decodes: the emoji and label default rather than
    /// failing the whole response.
    func testUnknownKindFallsBackToCatalogueDefaults() throws {
        let tallies = try decode("""
        { "pair": "p1", "kinds": [ { "kind": "sauna",
          "mine": { "day": 1, "week": 1, "month": 1, "all": 1 } } ] }
        """)

        XCTAssertEqual(tallies.kinds.count, 1)
        XCTAssertEqual(tallies.kinds[0].emoji, MomentCatalogue.fallbackEmoji)
        XCTAssertEqual(tallies.kinds[0].label, "Sauna")
    }

    func testRankedKindsOrdersByTotalThenAlphabetically() {
        let tallies = ConnectionTallies(
            pair: "p1", mine: .zero, others: .zero,
            kinds: [
                .init(kind: "walk", emoji: "🚶", label: "Walk", mine: TallyPeriods(day: 0, week: 0, month: 0, all: 1)),
                .init(kind: "beer", emoji: "🍺", label: "Beer", mine: TallyPeriods(day: 0, week: 0, month: 0, all: 9)),
                .init(kind: "coffee", emoji: "☕", label: "Coffee", mine: TallyPeriods(day: 0, week: 0, month: 0, all: 1)),
            ]
        )

        XCTAssertEqual(tallies.rankedKinds.map(\.kind.rawValue), ["beer", "coffee", "walk"])
    }

    // MARK: Pending merge

    private func pending(_ kind: EventKind, at created: String, pair: String = "p1") -> PendingSend {
        PendingSend(
            pairID: pair, authorID: "me", kind: kind,
            emoji: "🍺", label: "Beer", queuedAt: date(created)
        )
    }

    /// A moment logged with no signal has to move the number the moment it is
    /// tapped; waiting for the server would make the tap look like it did nothing.
    func testPendingSendsCountTowardsMyTallies() {
        let now = date("2026-07-28 12:00:00.000Z")
        let tallies = ConnectionTallies(
            pair: "p1",
            mine: TallyPeriods(day: 1, week: 1, month: 1, all: 1),
            others: TallyPeriods(day: 5, week: 5, month: 5, all: 5),
            kinds: [.init(kind: .beer, emoji: "🍺", label: "Beer",
                          mine: TallyPeriods(day: 1, week: 1, month: 1, all: 1))]
        )

        let merged = tallies.adding(
            pending: [pending(.beer, at: "2026-07-28 11:00:00.000Z")],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.mine, TallyPeriods(day: 2, week: 2, month: 2, all: 2))
        XCTAssertEqual(merged.kinds[0].mine.all, 2)
        // The other side is untouched: a queued send is by definition mine.
        XCTAssertEqual(merged.others, TallyPeriods(day: 5, week: 5, month: 5, all: 5))
    }

    func testPendingSendForAnotherConnectionIsIgnored() {
        let now = date("2026-07-28 12:00:00.000Z")
        let tallies = ConnectionTallies(pair: "p1", mine: .zero, others: .zero, kinds: [])

        let merged = tallies.adding(
            pending: [pending(.beer, at: "2026-07-28 11:00:00.000Z", pair: "other")],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.mine, .zero)
        XCTAssertTrue(merged.kinds.isEmpty)
    }

    /// A kind the server has never seen — the first time anybody logs it, while
    /// offline — still has to appear.
    func testPendingSendIntroducesAnUnseenKind() {
        let now = date("2026-07-28 12:00:00.000Z")
        let tallies = ConnectionTallies(pair: "p1", mine: .zero, others: .zero, kinds: [])

        let merged = tallies.adding(
            pending: [pending("sauna", at: "2026-07-28 11:00:00.000Z")],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.kinds.count, 1)
        XCTAssertEqual(merged.kinds[0].kind.rawValue, "sauna")
        XCTAssertEqual(merged.kinds[0].mine.day, 1)
    }

    /// The server's ordering is preserved as sends drain, so the tally list does
    /// not reshuffle underneath the user.
    func testServerOrderIsPreserved() {
        let now = date("2026-07-28 12:00:00.000Z")
        let tallies = ConnectionTallies(
            pair: "p1", mine: .zero, others: .zero,
            kinds: [
                .init(kind: .beer, emoji: "🍺", label: "Beer"),
                .init(kind: .loo, emoji: "💩", label: "Loo"),
            ]
        )

        let merged = tallies.adding(
            pending: [pending(.loo, at: "2026-07-28 11:00:00.000Z"), pending("sauna", at: "2026-07-28 11:30:00.000Z")],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.kinds.map(\.kind.rawValue), ["beer", "loo", "sauna"])
    }

    /// An older queued moment counts all-time but not today.
    func testPendingSendFromAnEarlierDayOnlyCountsAllTime() {
        let now = date("2026-07-28 12:00:00.000Z")
        let tallies = ConnectionTallies(pair: "p1", mine: .zero, others: .zero, kinds: [])

        let merged = tallies.adding(
            pending: [pending(.beer, at: "2026-07-20 09:00:00.000Z")],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.mine.day, 0)
        XCTAssertEqual(merged.mine.week, 0)
        XCTAssertEqual(merged.mine.month, 1)
        XCTAssertEqual(merged.mine.all, 1)
    }
}
