import XCTest
@testable import PeardCore

/// The home screen's poll backs off once pushes can do its job (issue #169).
final class HomePollTests: XCTestCase {
    func testWithoutPushesTheHomeScreenPollsEveryThirtySeconds() {
        XCTAssertEqual(HomePoll.interval(pushAuthorised: false), .seconds(30))
    }

    func testWithPushesAllowedItPollsEveryTwoMinutes() {
        XCTAssertEqual(HomePoll.interval(pushAuthorised: true), .seconds(120))
    }

    /// Slower, never off: silent pushes are throttled and only new moments send
    /// one, so the poll is still what catches a reaction or a rename.
    func testThePollNeverStopsAltogether() {
        XCTAssertGreaterThan(HomePoll.interval(pushAuthorised: true), .zero)
        XCTAssertLessThanOrEqual(HomePoll.interval(pushAuthorised: true), .seconds(300))
    }
}
