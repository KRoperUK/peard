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
}
