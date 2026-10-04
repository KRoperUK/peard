import XCTest
@testable import PeardCore

/// Re-reading a screen when its tab reappears, only when it is worth it
/// (issue #302's audit).
final class RefreshGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheFirstAppearanceAlwaysFetches() {
        XCTAssertTrue(RefreshGate().isDue(now: start))
    }

    /// The point of it: flicking between tabs is not a reason to fetch.
    func testAQuickReturnDoesNotFetchAgain() {
        var gate = RefreshGate(window: 30)
        gate.record(at: start)

        XCTAssertFalse(gate.isDue(now: start.addingTimeInterval(5)))
    }

    /// But a screen left alone longer than a poll would have waited is.
    func testAReturnAfterTheWindowFetches() {
        var gate = RefreshGate(window: 30)
        gate.record(at: start)

        XCTAssertTrue(gate.isDue(now: start.addingTimeInterval(30)))
    }

    /// A changed key means what the screen shows is out of date, however
    /// recently it was fetched.
    func testAChangedKeyAlwaysFetches() {
        var gate = RefreshGate(window: 30)
        gate.record(key: "a", at: start)

        XCTAssertFalse(gate.isDue(key: "a", now: start.addingTimeInterval(1)))
        XCTAssertTrue(gate.isDue(key: "b", now: start.addingTimeInterval(1)))
    }

    func testTheWindowIsTheFastestPoll() {
        XCTAssertEqual(RefreshGate.defaultWindow, 30)
        XCTAssertEqual(HomePoll.withoutPush, .seconds(RefreshGate.defaultWindow))
    }
}
