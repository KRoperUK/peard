import XCTest
@testable import PeardCore

/// The window-scoped views of a connection's per-kind tallies, which are what the
/// moment breakdown draws.
final class TallyWindowTests: XCTestCase {
    /// Beer is the week's most-logged, coffee leads today. The two orders differ,
    /// which is the whole reason the breakdown is scoped to a window rather than
    /// always ranking by all-time.
    private let tallies = ConnectionTallies(
        pair: "p1",
        mine: TallyPeriods(day: 1, week: 5, month: 5, all: 20),
        others: TallyPeriods(day: 2, week: 3, month: 3, all: 6),
        kinds: [
            .init(
                kind: .beer, emoji: "🍺", label: "Beer",
                mine: TallyPeriods(day: 0, week: 4, month: 4, all: 15),
                others: TallyPeriods(day: 1, week: 2, month: 2, all: 4)
            ),
            .init(
                kind: .coffee, emoji: "☕", label: "Coffee",
                mine: TallyPeriods(day: 1, week: 1, month: 1, all: 5),
                others: TallyPeriods(day: 1, week: 1, month: 1, all: 2)
            ),
            // Logged once, long ago: it belongs in All and in no other window.
            .init(
                kind: .loo, emoji: "💩", label: "Loo",
                mine: TallyPeriods(day: 0, week: 0, month: 0, all: 1),
                others: .zero
            ),
        ]
    )

    func testEachWindowReadsItsOwnField() {
        let periods = TallyPeriods(day: 1, week: 2, month: 3, all: 4)

        XCTAssertEqual(periods.count(in: .day), 1)
        XCTAssertEqual(periods.count(in: .week), 2)
        XCTAssertEqual(periods.count(in: .month), 3)
        XCTAssertEqual(periods.count(in: .all), 4)
    }

    func testKindTotalCombinesBothSidesInTheWindow() {
        let beer = tallies.kinds[0]

        XCTAssertEqual(beer.total(in: .day), 1)
        XCTAssertEqual(beer.total(in: .week), 6)
        XCTAssertEqual(beer.total(in: .all), 19)
        XCTAssertEqual(beer.count(in: .week, mine: true), 4)
        XCTAssertEqual(beer.count(in: .week, mine: false), 2)
    }

    /// Ranking follows the window, so "Today" is not ordered by a fortnight of
    /// history — coffee outranks beer today and the reverse is true for the week.
    func testRankingIsScopedToTheWindow() {
        XCTAssertEqual(tallies.rankedKinds(in: .day).map(\.kind.rawValue), ["coffee", "beer"])
        XCTAssertEqual(tallies.rankedKinds(in: .week).map(\.kind.rawValue), ["beer", "coffee"])
        XCTAssertEqual(tallies.rankedKinds(in: .all).map(\.kind.rawValue), ["beer", "coffee", "loo"])
    }

    /// A kind nobody logged in the window is left out rather than listed at zero:
    /// a twelve-moment catalogue would otherwise bury this morning's one moment.
    func testKindsWithNothingInTheWindowAreOmitted() {
        XCTAssertFalse(tallies.rankedKinds(in: .day).contains { $0.kind == .loo })
        XCTAssertTrue(tallies.rankedKinds(in: .all).contains { $0.kind == .loo })
    }

    /// The denominator is summed from the rows, so the bars always add up to the
    /// whole they are drawn against.
    func testWindowTotalSumsThePerKindRows() {
        XCTAssertEqual(tallies.total(in: .day), 3)
        XCTAssertEqual(tallies.total(in: .week), 8)
        // beer 15+4, coffee 5+2, loo 1+0.
        XCTAssertEqual(tallies.total(in: .all), 27)
    }

    /// The side totals can exceed the per-kind sum — a post saved with no kind
    /// counts for its author but belongs to no row. The bar must not be drawn
    /// against the larger number, or the parts would never reach the whole.
    func testWindowTotalCanTrailTheSideTotals() {
        let withUnkinded = ConnectionTallies(
            pair: "p1",
            mine: TallyPeriods(day: 0, week: 0, month: 0, all: 5),
            others: .zero,
            kinds: [.init(kind: .beer, emoji: "🍺", label: "Beer",
                          mine: TallyPeriods(day: 0, week: 0, month: 0, all: 3))]
        )

        XCTAssertEqual(withUnkinded.mine.all, 5)
        XCTAssertEqual(withUnkinded.total(in: .all), 3)
    }

    /// The fallback path against a server with no tallies endpoint can only
    /// produce side totals, so the breakdown has to be able to say it has nothing
    /// rather than render as an empty list.
    func testBreakdownIsUnavailableWithoutPerKindCounts() {
        XCTAssertTrue(tallies.hasKindBreakdown)
        XCTAssertFalse(ConnectionTallies.zero.hasKindBreakdown)
        XCTAssertFalse(
            ConnectionTallies(
                pair: "p1",
                mine: TallyPeriods(day: 1, week: 1, month: 1, all: 1),
                others: .zero,
                kinds: []
            ).hasKindBreakdown
        )
    }

    /// Every window has a label and an abbreviation, and the abbreviations are
    /// what the home screen's compact rows already print.
    func testWindowLabelsAreDistinct() {
        XCTAssertEqual(TallyWindow.allCases.map(\.shortLabel), ["Today", "Week", "Month", "All"])
        XCTAssertEqual(TallyWindow.allCases.map(\.initial), ["T", "W", "M", "All"])
        XCTAssertEqual(Set(TallyWindow.allCases.map(\.phrase)).count, TallyWindow.allCases.count)
    }

    /// A queued send has to show up in the breakdown too, not just the totals —
    /// otherwise tapping beer offline moves the row above and leaves beer's own
    /// count behind.
    func testPendingSendsAppearInTheWindowedBreakdown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let now = PeardDate.parse("2026-07-28 12:00:00.000Z")!

        let merged = tallies.adding(
            pending: [PendingSend(
                pairID: "p1", authorID: "me", kind: .loo,
                emoji: "💩", label: "Loo",
                queuedAt: PeardDate.parse("2026-07-28 11:00:00.000Z")!
            )],
            now: now, calendar: calendar
        )

        let looToday = merged.rankedKinds(in: .day).first { $0.kind == .loo }
        XCTAssertEqual(looToday?.count(in: .day, mine: true), 1)
        XCTAssertEqual(merged.total(in: .day), 4)
    }
}
