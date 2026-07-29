import XCTest
@testable import Peard
import PeardCore

/// The moment breakdown as `HomeModel` presents it.
///
/// The windowed ranking itself is pure and covered in PeardCore. What needs the app
/// target is the join: `momentTallies` merges the durable send queue into the
/// server's counts, and that merge is what decides whether a moment logged with no
/// signal shows up in the breakdown or only in the totals above it.
@MainActor
final class MomentBreakdownTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queue: SendQueue!
    private var storeURL: URL!

    private static let pairID = "pair1"

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-breakdown-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        app = AppModel(sendQueue: queue)
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: Self.pairID)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
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
}
