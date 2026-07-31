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

    /// The optimistic marker exists so a widget can acknowledge a tap before the
    /// round trip finishes. It must not be left behind by a failed attempt, or
    /// the widget keeps showing a moment that never landed.
    func testAFailedAttemptLeavesNoPendingMarker() async {
        store.widgetToken = "a-token"
        // Port 1 refuses immediately, so this exercises the request path and its
        // failure rather than the signed-out guard.
        store.apiBaseURLString = "http://127.0.0.1:1"

        let logged = await MomentLogging.perform(
            kind: .beer, pairID: nil, emoji: "🍺", label: "Beer", store: store
        )

        XCTAssertFalse(logged, "an unreachable server must not report success")
        XCTAssertNil(store.pendingWidgetLog)
    }
}
