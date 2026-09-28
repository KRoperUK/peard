import XCTest
@testable import PeardCore

/// Whether logging a moment reports what actually happened.
///
/// This used to return nothing at all, so the Messages extension inserted a
/// "🍺 Beer logged" bubble into somebody's conversation whether or not anything
/// had been logged. The result is only useful if a failure actually comes back
/// as `false`, which is what these cover.
final class MomentLoggingTests: XCTestCase {
    private var suiteName: String!
    private var store: SharedStore!

    override func setUp() {
        super.setUp()
        suiteName = "moment-logging-\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    /// Signed out — no widget token — is the case a Messages tray can be sitting
    /// in without knowing it, because signing out in the app clears the token
    /// underneath an extension that is already open.
    func testLoggingWithoutATokenReportsFailure() async {
        store.apiBaseURLString = "http://127.0.0.1:8090"

        let logged = await MomentLogging.perform(
            kind: .beer, pairID: nil, emoji: "🍺", label: "Beer", store: store
        )

        XCTAssertFalse(logged)
    }

    func testLoggingWithoutABaseURLReportsFailure() async {
        store.widgetToken = "a-token"

        let logged = await MomentLogging.perform(
            kind: .beer, pairID: nil, emoji: "🍺", label: "Beer", store: store
        )

        XCTAssertFalse(logged)
    }

    func testAnEmptyTokenIsTreatedAsSignedOut() async {
        store.widgetToken = ""
        store.apiBaseURLString = "http://127.0.0.1:8090"

        let logged = await MomentLogging.perform(
            kind: .beer, pairID: nil, emoji: "🍺", label: "Beer", store: store
        )

        XCTAssertFalse(logged)
    }

    /// The widget says how a tap went. A failure must never read as a moment
    /// that landed: it is kept, marked failed, so the widget can say "Couldn't
    /// log" instead of going quiet.
    func testAFailedAttemptIsMarkedFailed() async {
        store.widgetToken = "a-token"
        // Port 1 refuses immediately, so this exercises the request path and its
        // failure rather than the signed-out guard.
        store.apiBaseURLString = "http://127.0.0.1:1"

        let logged = await MomentLogging.perform(
            kind: .beer, pairID: nil, emoji: "🍺", label: "Beer", store: store
        )

        XCTAssertFalse(logged, "an unreachable server must not report success")
        XCTAssertEqual(store.pendingWidgetLog?.outcome, .failed)
        XCTAssertNotNil(store.pendingWidgetLog?.finishedAt)
    }

    // MARK: How long the widget shows it

    private let tapped = Date(timeIntervalSince1970: 1_790_000_000)

    func testAnOutcomeShowsForAFewSecondsAfterItIsKnown() {
        let log = PendingWidgetLog(pairID: "p", emoji: "🍺", label: "Beer", at: tapped)
            .finished(.logged, at: tapped.addingTimeInterval(0.4))

        XCTAssertEqual(log.visibleUntil, tapped.addingTimeInterval(0.4 + PendingWidgetLog.outcomeDisplay))
        XCTAssertTrue(log.isVisible(now: tapped.addingTimeInterval(2)))
        XCTAssertFalse(log.isVisible(now: tapped.addingTimeInterval(5)))
    }

    /// The extension was suspended before it heard back: "Logging…" must not
    /// stay up for ever.
    func testAnUnfinishedLogGivesUp() {
        let log = PendingWidgetLog(pairID: "p", emoji: "🍺", label: "Beer", at: tapped)

        XCTAssertNil(log.outcome)
        XCTAssertTrue(log.isVisible(now: tapped.addingTimeInterval(5)))
        XCTAssertFalse(log.isVisible(now: tapped.addingTimeInterval(PendingWidgetLog.maxAge + 1)))
    }

    /// A marker written by the previous build has no outcome fields.
    func testAnOlderMarkerStillDecodes() throws {
        let json = #"{"pairID":"p","emoji":"🍺","label":"Beer","at":0}"#
        let log = try JSONDecoder().decode(PendingWidgetLog.self, from: Data(json.utf8))
        XCTAssertNil(log.outcome)
        XCTAssertNil(log.finishedAt)
    }
}
