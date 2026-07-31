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
    private var suiteName: String!
    private var shared: SharedStore!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-routing-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        // A throwaway defaults suite rather than the real App Group: the privacy
        // gate reads from it, so sharing the device's container would make these
        // tests pass or fail depending on whether whoever ran them last had
        // agreed to the policy in the simulator.
        suiteName = "peard-routing-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        app = AppModel(sharedStore: shared, sendQueue: queue)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        UserDefaults().removePersistentDomain(forName: suiteName)
        app = nil
        queue = nil
        shared = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: Privacy gate

    /// The promise the consent screen makes is that nothing leaves the device
    /// first. `bootstrap` is where that is kept or broken, so it is asserted
    /// here rather than left to the screen's copy.
    func testLaunchWithoutConsentStopsAtTheGate() async {
        shared.clearPrivacyConsent()

        await app.bootstrap()

        XCTAssertEqual(app.phase, .consent)
        XCTAssertTrue(app.isFirstPrivacyPrompt)
    }

    func testAgreeingContinuesTheLaunch() async {
        shared.clearPrivacyConsent()
        await app.bootstrap()

        await app.agreeToPrivacyPolicy()

        XCTAssertTrue(app.hasAgreedToPrivacyPolicy)
        XCTAssertEqual(app.phase, .auth, "with consent and no session, the launch lands on sign-in")
    }

    /// An invite link is the one route into the app that skips launch routing.
    /// Following it on a fresh install would open the pairing screen, which
    /// immediately redeems the code against the server.
    func testDeepLinkWithoutConsentIsHeldAtTheGate() {
        shared.clearPrivacyConsent()

        app.handle(url: URL(string: "peard://pair/ABC123")!)

        XCTAssertEqual(app.phase, .consent)
    }

    /// Agreeing once is enough. Signing out drops the session, not the record.
    func testSigningOutKeepsTheAgreement() async {
        await app.signOut()

        XCTAssertTrue(app.hasAgreedToPrivacyPolicy)
        XCTAssertEqual(app.phase, .auth)
    }

    /// A policy the user has not seen puts the gate back, and the screen knows
    /// to say "updated" rather than "before you sign in".
    func testASupersededAgreementReopensTheGate() async {
        shared.recordPrivacyConsent(version: "1970-01-01")

        await app.bootstrap()

        XCTAssertEqual(app.phase, .consent)
        XCTAssertFalse(app.isFirstPrivacyPrompt)
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

    // MARK: Foreground

    /// The foreground hook was defined and never called for a while, so a moment
    /// queued offline waited for a cold launch. This asserts the model side is
    /// callable and harmless without a session; the wiring itself lives in
    /// `PeardApp`'s `scenePhase` observer, which a unit test cannot reach.
    func testForegroundRefreshKeepsAQueuedMoment() async {
        await app.attachSendQueue()
        await app.enqueue(sample())

        await app.applicationDidBecomeActive()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1, "a foreground with no session must not discard anything")
    }

    /// Coming back to the foreground is a network-touching moment like any
    /// other, so it is behind the same gate as launch.
    func testForegroundRefreshIsHeldAtThePrivacyGate() async {
        shared.clearPrivacyConsent()
        await app.attachSendQueue()
        await app.enqueue(sample())

        await app.applicationDidBecomeActive()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1)
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
