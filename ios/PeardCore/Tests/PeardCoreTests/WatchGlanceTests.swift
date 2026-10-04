import XCTest
@testable import PeardCore

/// The watch's log-again tile, its line of today's counts, and the Smart Stack's
/// interest in the rectangular widget (issue #287).
final class WatchGlanceTests: XCTestCase {
    private let moments: [WidgetFeed.AvailableMoment] = [
        .init(kind: .beer, emoji: "🍺", label: "Beer"),
        .init(kind: .loo, emoji: "💩", label: "Loo"),
        .init(kind: .coffee, emoji: "☕", label: "Coffee"),
        .init(kind: EventKind(rawValue: "tea"), emoji: "🫖", label: "Tea"),
    ]

    // MARK: Log again

    func testTheLastMomentIsOfferedAgain() {
        XCTAssertEqual(WatchGlance.logAgain(lastKind: "tea", in: moments, firstRow: 3)?.label, "Tea")
    }

    /// Already on screen in the first row, so a tile would be a second copy of
    /// the same button.
    func testAMomentInTheFirstRowIsNotRepeated() {
        XCTAssertNil(WatchGlance.logAgain(lastKind: "coffee", in: moments, firstRow: 3))
    }

    /// A custom moment deleted since it was last logged is not offered from
    /// memory.
    func testAMomentTheConnectionNoLongerOffersIsDropped() {
        XCTAssertNil(WatchGlance.logAgain(lastKind: "sauna", in: moments, firstRow: 3))
    }

    func testNothingLoggedYetMeansNoTile() {
        XCTAssertNil(WatchGlance.logAgain(lastKind: nil, in: moments, firstRow: 3))
    }

    func testTheLastMomentIsKeptPerConnection() {
        let suite = "watch-last-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: UserDefaults(suiteName: suite))

        store.setLastWatchMoment("tea", forConnection: "flat")
        store.setLastWatchMoment("beer", forConnection: "pair")
        store.setLastWatchMoment("coffee", forConnection: "pair")

        XCTAssertEqual(store.lastWatchMoment(forConnection: "flat"), "tea")
        XCTAssertEqual(store.lastWatchMoment(forConnection: "pair"), "coffee")
        XCTAssertNil(store.lastWatchMoment(forConnection: "other"))
    }

    // MARK: Today

    private func feed(isGroup: Bool = false, tallies: [WidgetFeed.Tally]) -> WidgetFeed {
        WidgetFeed(
            state: .ok,
            partner: .init(name: "Sam"),
            connection: .init(id: "p1", name: isGroup ? "Flatmates" : nil, memberCount: isGroup ? 4 : 2, isGroup: isGroup),
            tallies: tallies
        )
    }

    private let counts: [WidgetFeed.Tally] = [
        .init(kind: .coffee, emoji: "☕", label: "Coffee", count: 3),
        .init(kind: .beer, emoji: "🍺", label: "Beer", count: 1),
    ]

    /// Named for the partner, because the server counts only their moments and
    /// a count that ignores your own taps would otherwise look broken.
    func testAPairsLineIsNamedForThePartner() {
        XCTAssertEqual(WatchGlance.todayLine(feed(tallies: counts)), "Sam today  ☕ 3  🍺 1")
    }

    /// In a group the feed's partner is only whoever posted last.
    func testAGroupsLineIsNamedForEveryoneElse() {
        XCTAssertEqual(WatchGlance.todayLine(feed(isGroup: true, tallies: counts)), "Others today  ☕ 3  🍺 1")
    }

    func testNoCountsMeansNoLine() {
        XCTAssertNil(WatchGlance.todayLine(feed(tallies: [])))
        XCTAssertNil(WatchGlance.todayAccessibilityLabel(feed(tallies: [])))
    }

    func testVoiceOverHearsTheCountsInWords() {
        XCTAssertEqual(
            WatchGlance.todayAccessibilityLabel(feed(tallies: counts)),
            "Today from Sam: 3 Coffee, 1 Beer"
        )
    }

    // MARK: Smart Stack

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(at: Date?, state: FeedState = .ok) -> LockScreenSummary {
        LockScreenSummary(state: state, partnerName: "Sam", emoji: "☕", created: at)
    }

    func testAMomentThatJustLandedIsMostRelevantUntilItIsNoLongerFresh() {
        let relevance = WatchGlance.smartStackRelevance(summary(at: now.addingTimeInterval(-10 * 60)), now: now)

        XCTAssertEqual(relevance.score, 100)
        XCTAssertEqual(relevance.duration, 20 * 60)
    }

    func testAnHourOldMomentIsLessRelevant() {
        let relevance = WatchGlance.smartStackRelevance(summary(at: now.addingTimeInterval(-60 * 60)), now: now)

        XCTAssertEqual(relevance.score, 40)
        XCTAssertEqual(relevance.duration, 2 * 60 * 60)
    }

    func testAnOldMomentIsNotRelevant() {
        XCTAssertEqual(WatchGlance.smartStackRelevance(summary(at: now.addingTimeInterval(-4 * 60 * 60)), now: now).score, 0)
    }

    /// A prompt has nothing new to show, however recent the clock says it is.
    func testAPromptIsNotRelevant() {
        XCTAssertEqual(WatchGlance.smartStackRelevance(summary(at: now, state: .empty), now: now).score, 0)
        XCTAssertEqual(WatchGlance.smartStackRelevance(summary(at: nil), now: now).score, 0)
    }

    /// A server clock slightly ahead must not make a moment older than fresh.
    func testAMomentFromTheFutureCountsAsJustLanded() {
        let relevance = WatchGlance.smartStackRelevance(summary(at: now.addingTimeInterval(60)), now: now)

        XCTAssertEqual(relevance.score, 100)
        XCTAssertEqual(relevance.duration, WatchGlance.freshFor)
    }
}
