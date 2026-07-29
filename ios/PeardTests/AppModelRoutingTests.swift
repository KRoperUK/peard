import XCTest
@testable import Peard
import PeardCore

/// `AppModel`'s routing and queue plumbing.
///
/// These are the paths a user hits on every launch and every notification tap, and
/// none of them were reachable from `swift test` because `AppModel` is
/// `@MainActor @Observable` and lives in the app target.
@MainActor
final class AppModelRoutingTests: XCTestCase {
    private var app: AppModel!
    private var queue: SendQueue!
    private var storeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-routing-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        app = AppModel(sendQueue: queue)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        app = nil
        queue = nil
        try await super.tearDown()
    }

    // MARK: Phase

    func testStartsInLoading() {
        XCTAssertEqual(app.phase, .loading)
        XCTAssertFalse(app.phase.isHome)
    }

    func testHomePhaseReportsItself() {
        XCTAssertTrue(AppModel.Phase.home(pairID: "p1").isHome)
        XCTAssertFalse(AppModel.Phase.pair(prefilledCode: nil).isHome)
        XCTAssertFalse(AppModel.Phase.auth.isHome)
    }

    /// Requirement 19.1 — a `peard://pair/CODE` link opens pairing with the code
    /// filled in, which is what makes an invite a single tap for the recipient.
    func testPairDeepLinkPrefillsTheCode() {
        app.handle(url: URL(string: "peard://pair/ABC123")!)

        XCTAssertEqual(app.phase, .pair(prefilledCode: "ABC123"))
    }

    func testUnrecognisedDeepLinkIsIgnored() {
        app.handle(url: URL(string: "peard://nonsense")!)

        XCTAssertEqual(app.phase, .loading, "an unknown link must not move the user")
    }

    /// Selecting a connection that is not in the list must not route anywhere: it
    /// would leave the home screen pointed at a pair the user cannot read.
    func testSelectingAnUnknownConnectionIsRefused() {
        app.select(connectionID: "ghost")

        XCTAssertEqual(app.phase, .loading)
    }

    func testCanReturnHomeOnlyWithAConnection() {
        XCTAssertFalse(app.canReturnHome)
    }

    // MARK: Queue plumbing

    func testEnqueuedSendIsVisibleToTheUI() async {
        await app.attachSendQueue()
        await app.enqueue(sample())

        XCTAssertEqual(app.pendingSends.count, 1)
        XCTAssertEqual(app.pendingSends.first?.kind, .beer)
    }

    func testPendingSendsAreFilteredByConnection() async {
        await app.attachSendQueue()
        await app.enqueue(sample(pair: "p1"))
        await app.enqueue(sample(pair: "p2"))

        XCTAssertEqual(app.pendingSends.count, 2)
        XCTAssertEqual(app.pendingSends(forConnection: "p1").count, 1)
        XCTAssertEqual(app.pendingSends(forConnection: "p2").count, 1)
        XCTAssertEqual(app.pendingSends(forConnection: "p3").count, 0)
    }

    /// A flush with no session must not fire requests: there is no token to send
    /// them with, and every one would come back 401 and burn a retry.
    func testFlushIsSkippedWithoutASession() async {
        await app.enqueue(sample())

        let result = await app.flushSendQueueAndWait()

        XCTAssertEqual(result.sent, 0)
        let stillQueued = await queue.count
        XCTAssertEqual(stillQueued, 1, "the moment must be kept, not discarded")
    }

    /// Signing out discards the queue: a queued send carries an author id the next
    /// account cannot post under, so keeping it would only produce failures.
    func testSignOutClearsTheQueue() async {
        await app.enqueue(sample())

        await app.signOut()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(app.phase, .auth)
    }

    /// A 401 is not a sign-out: the same person will sign back in, and their
    /// moments have to survive that.
    func testExpiredSessionKeepsTheQueue() async {
        await app.enqueue(sample())

        await app.clearSessionAndReturnToAuth()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1, "an expired token must not cost somebody their moments")
        XCTAssertEqual(app.phase, .auth)
    }

    // MARK: Helpers

    private func sample(pair: String = "p1") -> PendingSend {
        PendingSend(pairID: pair, authorID: "me", kind: .beer, emoji: "🍺", label: "Beer")
    }
}
