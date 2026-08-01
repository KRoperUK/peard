import XCTest
@testable import Peard
import PeardCore

/// Which connection the Messages tray logs into.
///
/// The tray used to pass `nil` and let the server pick whichever connection it
/// judged liveliest. From a home-screen widget that is a reasonable guess; from
/// a tray opened inside a conversation with a specific person it is a guess
/// about the one thing that actually matters, and one the tray could not then
/// report — you tapped, something was logged, and nothing said where.
///
/// Nothing in Messages tells an extension who the other participants are, so it
/// still cannot be inferred. This is what it does instead.
@MainActor
final class MomentTrayModelTests: XCTestCase {
    private var store: SharedStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "peard-tray-\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Signed out

    /// No widget token means the app has never been signed in, and the tray has
    /// nothing to offer but an explanation.
    func testWithoutASessionTheTraySaysSo() async {
        let model = MomentTrayModel(store: store)

        await model.load()

        XCTAssertEqual(model.phase, .signedOut)
    }

    // MARK: The built-in fallback

    /// Before anything is fetched — and if the catalogue cannot be fetched at
    /// all — the three every connection has are still offered. A tray that
    /// cannot log a beer because a secondary request failed is worse than one
    /// missing the custom moments.
    func testTheBuiltInMomentsAreThereFromTheStart() {
        let model = MomentTrayModel(store: store)

        XCTAssertEqual(model.moments.map(\.kind), [.beer, .loo, .coffee])
    }

    // MARK: Choosing

    func testAChoiceIsOnlyOfferedWhenThereIsOne() {
        let model = MomentTrayModel(store: store)

        XCTAssertFalse(model.canChooseConnection, "one connection is not a choice")
    }

    // MARK: Remembering

    /// The tray's own last choice is kept apart from the app's. Which
    /// connection you log into from a chat is not the same question as which
    /// one the app should open on, and writing the app's answer from inside an
    /// extension would move somebody's home screen without being asked.
    func testTheTraysChoiceIsItsOwn() {
        store.selectedConnectionID = "app-choice"
        store.messagesConnectionID = "tray-choice"

        XCTAssertEqual(store.selectedConnectionID, "app-choice")
        XCTAssertEqual(store.messagesConnectionID, "tray-choice")
    }

    func testTheTraysChoiceSurvivesBeingReadBack() {
        store.messagesConnectionID = "pair-1"

        let reopened = SharedStore(defaults: UserDefaults(suiteName: suiteName))

        XCTAssertEqual(reopened.messagesConnectionID, "pair-1")
    }

    func testClearingTheTraysChoiceRemovesIt() {
        store.messagesConnectionID = "pair-1"

        store.messagesConnectionID = nil

        XCTAssertNil(store.messagesConnectionID)
    }

    // MARK: Status

    /// The line under the buttons names where the moment went. "Beer logged" on
    /// its own is half a sentence in an app where a moment can land in any of
    /// twenty connections.
    func testTheLoggedStatusCarriesBothTheMomentAndTheConnection() {
        let status = MomentTrayModel.Status.logged(moment: "Beer", connection: "Flatmates")

        guard case .logged(let moment, let connection) = status else {
            return XCTFail("expected a logged status")
        }
        XCTAssertEqual(moment, "Beer")
        XCTAssertEqual(connection, "Flatmates")
    }

    func testAnIdleTrayIsNotBusy() {
        let model = MomentTrayModel(store: store)

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.status, .idle)
    }

    // MARK: The summary

    private func feed(
        state: FeedState = .ok,
        partner: String? = "Sam",
        isGroup: Bool = false,
        tallies: [WidgetFeed.Tally]? = nil,
        post: WidgetFeed.FeedPost? = nil
    ) -> WidgetFeed {
        WidgetFeed(
            state: state,
            partner: partner.map { WidgetFeed.Partner(name: $0) },
            connection: WidgetFeed.ConnectionInfo(id: "p1", name: "Flatmates", memberCount: isGroup ? 3 : 2, isGroup: isGroup),
            tallies: tallies,
            post: post
        )
    }

    /// Before anything is fetched there is nothing to say, and the tray shows
    /// its own empty line rather than a heading with no numbers under it.
    func testWithoutAFeedTheSummaryIsEmpty() {
        XCTAssertTrue(MomentTrayModel.summary(from: nil).isEmpty)
        XCTAssertEqual(MomentTrayModel.summary(from: nil), .none)
    }

    /// The counts exclude your own posts — the endpoint filters `author != user`
    /// — so the heading has to say whose day it is. Without it, tapping Coffee
    /// and watching the coffee count sit still reads as a broken counter.
    func testTheHeadingNamesThePersonTheCountsBelongTo() {
        let summary = MomentTrayModel.summary(from: feed(partner: "Sam"))

        XCTAssertEqual(summary.heading, "Sam today")
    }

    /// In a group the counts mix everybody but you, so naming one member would
    /// be wrong about the other two.
    func testAGroupHeadingNamesNobody() {
        let summary = MomentTrayModel.summary(from: feed(isGroup: true))

        XCTAssertEqual(summary.heading, "Everyone else today")
    }

    func testTheTalliesComeThroughInOrder() {
        let summary = MomentTrayModel.summary(from: feed(tallies: [
            .init(kind: .coffee, emoji: "☕", label: "Coffee", count: 3),
            .init(kind: .beer, emoji: "🍺", label: "Beer", count: 1),
        ]))

        XCTAssertEqual(summary.tallies.map(\.count), [3, 1])
        XCTAssertEqual(summary.tallies.map(\.emoji), ["☕", "🍺"])
        XCTAssertFalse(summary.isEmpty)
    }

    func testTheLatestMomentCarriesItsAuthorNoteAndTime() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = MomentTrayModel.summary(from: feed(post: .init(
            id: "1", type: .event, eventKind: .coffee, emoji: "☕", label: "Coffee",
            note: "second one, don't judge", created: when, author: "Sam"
        )))

        XCTAssertEqual(summary.latest?.emoji, "☕")
        XCTAssertEqual(summary.latest?.label, "Coffee")
        XCTAssertEqual(summary.latest?.author, "Sam")
        XCTAssertEqual(summary.latest?.note, "second one, don't judge")
        XCTAssertEqual(summary.latest?.at, when)
    }

    /// A photo post has no `event_kind`, so the usual label resolves to an empty
    /// string. "📸" with nothing after it is not a sentence.
    func testAPhotoIsLabelledAsOne() {
        let summary = MomentTrayModel.summary(from: feed(post: .init(
            id: "1", type: .photo, mediaURL: "https://example.com/a.jpg", author: "Sam"
        )))

        XCTAssertEqual(summary.latest?.emoji, "📸")
        XCTAssertEqual(summary.latest?.label, "Photo")
    }

    /// An empty note is not a note. The row would render a dangling "·".
    func testAnEmptyNoteIsNotShown() {
        let summary = MomentTrayModel.summary(from: feed(post: .init(
            id: "1", type: .event, eventKind: .beer, note: "", author: "Sam"
        )))

        XCTAssertNil(summary.latest?.note)
    }

    /// The server resolves the author to a display name, but a member it cannot
    /// resolve leaves it blank, and "· logged a beer" with no subject is worse
    /// than the connection's own fallback name.
    func testAnUnresolvedAuthorFallsBackToThePartnerName() {
        let summary = MomentTrayModel.summary(from: feed(partner: "Sam", post: .init(
            id: "1", type: .event, eventKind: .beer, author: ""
        )))

        XCTAssertEqual(summary.latest?.author, "Sam")
    }

    /// Nothing today and nothing ever is the state a brand new connection is in,
    /// and the tray should not draw a heading over three dashes.
    func testAFeedWithNothingInItIsEmpty() {
        XCTAssertTrue(MomentTrayModel.summary(from: feed(state: .empty)).isEmpty)
    }

    /// A feed for a connection you are not in has nothing to summarise, heading
    /// included.
    func testAnUnpairedFeedSummarisesToNothing() {
        let summary = MomentTrayModel.summary(from: feed(state: .unpaired, tallies: [
            .init(kind: .beer, emoji: "🍺", label: "Beer", count: 2),
        ]))

        XCTAssertEqual(summary, .none)
    }

    // MARK: The catalogue

    /// The buttons still fall back to the built-ins when the feed cannot be
    /// fetched — that behaviour predates the summary and survives it.
    func testTheMomentsFallBackWhenTheFeedHasNoCatalogue() {
        let model = MomentTrayModel(store: store)

        XCTAssertEqual(model.moments.map(\.kind), [.beer, .loo, .coffee])
    }
}
