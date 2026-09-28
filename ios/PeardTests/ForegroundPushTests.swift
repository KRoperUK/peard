import PeardCore
import UserNotifications
import XCTest
@testable import Peard

/// What an alert that arrives with the app open does (issue #140): a banner,
/// unless it is about the connection on screen, which refreshes instead.
@MainActor
final class ForegroundPushTests: XCTestCase {
    private var push: PushCoordinator!
    private var suiteName: String!
    private var refreshes = 0
    private var refreshed: XCTestExpectation?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "peard-foreground-push-\(UUID().uuidString)"
        push = PushCoordinator(
            api: APIClient(baseURL: URL(string: "https://peard.invalid")!),
            session: KeychainSessionStore(service: suiteName),
            store: SharedStore(defaults: UserDefaults(suiteName: suiteName))
        )
        refreshes = 0
        push.onRefreshConnectionOnScreen = { [weak self] in
            self?.refreshes += 1
            self?.refreshed?.fulfill()
        }
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        push = nil
        suiteName = nil
        refreshed = nil
        try await super.tearDown()
    }

    func testAnAlertForTheConnectionOnScreenRefreshesItInsteadOfBannering() async {
        push.connectionOnScreen = { "pair1" }
        refreshed = expectation(description: "the screen refreshes")

        let options = push.foregroundPresentation(for: MomentPush(postID: "post1", pairID: "pair1", eventKind: .beer))

        XCTAssertEqual(options, [], "no banner, no sound, nothing left in Notification Centre")
        await fulfillment(of: [refreshed!], timeout: 2)
        XCTAssertEqual(refreshes, 1)
    }

    func testAnAlertForAnotherConnectionStillBanners() async {
        push.connectionOnScreen = { "pair2" }

        let options = push.foregroundPresentation(for: MomentPush(postID: "post1", pairID: "pair1"))

        XCTAssertEqual(options, [.banner, .sound])
        await Task.yield()
        XCTAssertEqual(refreshes, 0)
    }

    func testAnAlertWithNoConnectionOnScreenBanners() {
        push.connectionOnScreen = { nil }

        XCTAssertEqual(push.foregroundPresentation(for: MomentPush(postID: "post1", pairID: "pair1")), [.banner, .sound])
    }

    /// The weekly recap names the connection but no post, so it does not parse
    /// as a moment — and is shown even while that connection is on screen.
    func testAnAlertThatIsNotAMomentBanners() {
        push.connectionOnScreen = { "pair1" }
        let recap = MomentPush(userInfo: ["pair_id": "pair1"])

        XCTAssertEqual(push.foregroundPresentation(for: recap), [.banner, .sound])
    }
}
