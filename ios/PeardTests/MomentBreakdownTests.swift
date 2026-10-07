import XCTest
@testable import Peard
import PeardCore
import SwiftUI

/// The moment breakdown as `HomeModel` presents it.
///
/// The windowed ranking itself is pure and covered in PeardCore. What needs the app
/// target is the join: `momentTallies` merges the durable send queue into the
/// server's counts, and that merge is what decides whether a moment logged with no
/// signal shows up in the breakdown or only in the totals above it.
///
/// The session store is a throwaway keychain service, for the same reason the
/// send queue is a throwaway file: with the device's real one, whether these
/// pass depends on whether somebody happens to be signed in on this simulator
/// *and* whether a dev server happens to be running — because a queue that
/// flushes successfully is an empty queue, and every assertion here is about
/// what is still in it. That combination made 22 of these fail on a machine
/// where nothing was wrong with the code.
@MainActor
final class MomentBreakdownTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queue: SendQueue!
    private var storeURL: URL!
    private var sessionStore: KeychainSessionStore!

    private static let pairID = "pair1"

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-breakdown-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        sessionStore = KeychainSessionStore(service: "peard-breakdown-test-\(UUID().uuidString)")
        sessionStore.clear()
        app = AppModel(sessionStore: sessionStore, sendQueue: queue)
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: Self.pairID)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        sessionStore?.clear()
        sessionStore = nil
        model = nil
        app = nil
        queue = nil
        try await super.tearDown()
    }

    /// Published so tapping it needs no network round trip first.
    private func moment(_ slug: String, _ emoji: String, _ label: String) -> Moment {
        Moment(kind: EventKind(rawValue: slug), emoji: emoji, label: label, origin: .custom(recordID: "rec-\(slug)"))
    }

    /// Logs a moment the way the UI does, waiting for the commit to land.
    private func log(_ moment: Moment, times: Int = 1) async {
        for _ in 0..<times {
            model.tap(moment: moment)
            await model.sendNow()
        }
    }

    // MARK: Availability

    /// A fresh connection has counted nothing, so there is nothing to break down —
    /// and the section has to know that rather than render an empty list.
    func testBreakdownIsUnavailableBeforeAnythingIsLogged() {
        XCTAssertFalse(model.hasMomentBreakdown)
        XCTAssertTrue(model.topMoments.isEmpty)
    }

    /// The counts are seeded with the connection's id rather than `.zero`, whose
    /// `pair` is empty and would silently drop every queued send. Guarding it here
    /// because the failure is invisible: the totals simply stay at nought.
    func testTalliesAreSeededWithTheConnectionSoQueuedSendsMatch() {
        XCTAssertEqual(model.momentTallies.pair, Self.pairID)
    }

    // MARK: Queued sends

    /// A moment logged with no signal must appear in the breakdown immediately,
    /// for the same reason it moves the tally: waiting for delivery would make the
    /// tap look like it did nothing.
    func testQueuedMomentAppearsInTheBreakdown() async {
        await log(moment("beer", "🍺", "Beer"))

        XCTAssertTrue(model.hasMomentBreakdown)
        XCTAssertEqual(model.topMoments.map(\.kind.rawValue), ["beer"])

        guard let beer = model.topMoments.first else { return XCTFail("no beer row") }
        XCTAssertEqual(beer.emoji, "🍺")
        XCTAssertEqual(beer.label, "Beer")
        XCTAssertEqual(beer.total, 1)
        // A queued send is the user's own, so it must land on their side only.
        XCTAssertEqual(beer.count(in: .day, mine: true), 1)
        XCTAssertEqual(beer.count(in: .day, mine: false), 0)
    }

    func testQueuedMomentsAppearInEveryWindow() async {
        await log(moment("beer", "🍺", "Beer"))

        for window in TallyWindow.allCases {
            XCTAssertEqual(
                model.momentTallies.rankedKinds(in: window).map(\.kind.rawValue), ["beer"],
                "\(window.shortLabel) should list a moment logged just now"
            )
            XCTAssertEqual(model.momentTallies.total(in: window), 1, "\(window.shortLabel) total")
        }
    }

    /// The strip and the sheet both rank by how much a moment is used, so the
    /// order has to follow the counts rather than the order they were logged in.
    func testMostLoggedMomentRanksFirst() async {
        await log(moment("coffee", "☕", "Coffee"))
        await log(moment("beer", "🍺", "Beer"), times: 3)

        XCTAssertEqual(model.topMoments.map(\.kind.rawValue), ["beer", "coffee"])
        XCTAssertEqual(model.topMoments.first?.total, 3)
    }

    /// The home screen's strip is one line and has to stay one line, however many
    /// moments a connection invents. The full list is behind it.
    func testTopMomentsAreCappedForTheOneLineStrip() async {
        for slug in ["beer", "coffee", "loo", "tea", "wine", "gym"] {
            await log(moment(slug, "🍐", slug.capitalized))
        }

        XCTAssertEqual(model.momentTallies.kinds.count, 6)
        XCTAssertEqual(model.topMoments.count, 4)
    }

    /// The bars are drawn against this, so it has to be the sum of the rows.
    func testWindowTotalMatchesTheSumOfTheRows() async {
        await log(moment("beer", "🍺", "Beer"), times: 2)
        await log(moment("coffee", "☕", "Coffee"))

        let summed = model.momentTallies.kinds.reduce(0) { $0 + $1.total(in: .all) }
        XCTAssertEqual(model.momentTallies.total(in: .all), summed)
        XCTAssertEqual(model.momentTallies.total(in: .all), 3)
    }

    /// A moment nobody has published yet still has to draw its own emoji and label
    /// in the breakdown: the connection's catalogue cannot name it, so a lookup
    /// would fall back to the pear.
    func testUnpublishedMomentKeepsItsOwnEmojiAndLabel() async {
        let invented = Moment(kind: "sauna", emoji: "🧖", label: "Sauna", origin: .custom(recordID: nil))
        await log(invented)

        guard let row = model.topMoments.first else { return XCTFail("no row") }
        XCTAssertEqual(row.emoji, "🧖")
        XCTAssertEqual(row.label, "Sauna")
    }

    /// A send belonging to another connection must not leak into this one's
    /// breakdown.
    func testAnotherConnectionsQueuedSendIsExcluded() async {
        await app.enqueue(PendingSend(
            pairID: "someone-else",
            authorID: model.signedInUserID,
            kind: .beer,
            emoji: "🍺",
            label: "Beer"
        ))

        XCTAssertFalse(model.hasMomentBreakdown)
        XCTAssertTrue(model.topMoments.isEmpty)
    }

    // MARK: Water today (#320)

    private var water: Moment { moment("water", "💧", "Water") }

    /// Logs a glass the way the UI does: tap, choose a size, send.
    private func drink(_ ml: Int?) async {
        model.tap(moment: water)
        model.setQuickSendAmount(ml)
        await model.sendNow()
    }

    func testTodaysWaterTotalSumsEveryQueuedAmount() async {
        await drink(330)
        await drink(500)
        await drink(500)

        XCTAssertEqual(model.momentTallies.waterToday, 1330)
        XCTAssertEqual(WaterAmount.todayLabel(model.momentTallies.waterToday, locale: Locale(identifier: "en_GB")), "1,330 ml today")
    }

    /// Queued sends are the user's own, so the millilitres land on their side.
    func testQueuedWaterLandsOnTheUsersSide() async {
        await drink(330)

        let kind = model.momentTallies.kinds.first { $0.kind == .water }
        XCTAssertEqual(kind?.mine.dayAmount, 330)
        XCTAssertEqual(kind?.others.dayAmount, 0)
    }

    /// A water moment with no size is a moment, and adds nothing to the total.
    func testWaterWithoutAnAmountAddsNothingToTheTotal() async {
        await drink(330)
        await drink(nil)

        XCTAssertEqual(model.momentTallies.waterToday, 330)
        XCTAssertEqual(model.momentTallies.kinds.first { $0.kind == .water }?.mine.day, 2)
    }

    func testNothingButWaterAddsToTheWaterTotal() async {
        await drink(250)
        await log(moment("beer", "🍺", "Beer"), times: 2)

        XCTAssertEqual(model.momentTallies.waterToday, 250)
    }

    // MARK: Water targets (#321)

    private let gb = Locale(identifier: "en_GB")

    private func todaysProgress() -> WaterProgress {
        WaterProgress(ml: model.momentTallies.waterToday)
    }

    func testNoTargetProgressUntilSomeoneLogsWater() async {
        XCTAssertEqual(todaysProgress().stage, .none)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(todaysProgress(), locale: gb), "")

        await log(moment("beer", "🍺", "Beer"))
        XCTAssertEqual(todaysProgress().stage, .none, "other moments are not water")
    }

    func testQueuedWaterShowsProgressUnderTheMinimum() async {
        await drink(330)
        await drink(500)

        let progress = todaysProgress()
        XCTAssertEqual(progress.stage, .underMinimum)
        XCTAssertEqual(progress.fraction, 0.415, accuracy: 0.0001)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(progress, locale: gb), "670 ml to the 1,500 ml minimum")
    }

    func testQueuedWaterReachesTheMinimumBeforeTheGoal() async {
        await drink(500)
        await drink(500)
        await drink(500)

        let progress = todaysProgress()
        XCTAssertEqual(progress.stage, .minimumMet)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(progress, locale: gb), "Minimum met · 500 ml to the 2,000 ml goal")
    }

    func testMeetingTheGoalReadsDifferentlyFromBeingUnderIt() async {
        await drink(500)
        let under = todaysProgress()
        await drink(500)
        await drink(500)
        await drink(500)
        let met = todaysProgress()

        XCTAssertFalse(under.isRecommendedMet)
        XCTAssertTrue(met.isRecommendedMet)
        XCTAssertEqual(met.stage, .recommendedMet)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(met, locale: gb), "Goal met · 2,000 ml")
        XCTAssertNotEqual(
            MomentBreakdownCopy.waterProgress(under, locale: gb),
            MomentBreakdownCopy.waterProgress(met, locale: gb)
        )
    }

    func testTheWaterSectionRendersWithProgress() async throws {
        await drink(500)
        let section = WaterTodaySection(tallies: model.momentTallies, mineLabel: "You", othersLabel: "Ari")

        let image = ImageRenderer(content: Form { section }.frame(width: 360, height: 240))
        XCTAssertNotNil(image.uiImage, "the section should lay out with its progress bar")
    }

    func testTheSplitNamesOnlyTheSidesThatDrank() {
        XCTAssertEqual(MomentBreakdownCopy.waterSplit(mine: 830, others: 0, mineLabel: "You", othersLabel: "Ari"), "You 830 ml")
        XCTAssertEqual(MomentBreakdownCopy.waterSplit(mine: 0, others: 250, mineLabel: "You", othersLabel: "Ari"), "Ari 250 ml")
        XCTAssertEqual(
            MomentBreakdownCopy.waterSplit(mine: 830, others: 250, mineLabel: "You", othersLabel: "Ari"),
            "You 830 ml · Ari 250 ml"
        )
        XCTAssertEqual(MomentBreakdownCopy.waterSplit(mine: 0, others: 0, mineLabel: "You", othersLabel: "Ari"), "")
    }
}
