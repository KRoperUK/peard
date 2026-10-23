import XCTest
@testable import Peard
import PeardCore

/// Turning a metric on, off, and on again (#390, #411).
///
/// Zero is how the store says "not tracked", so a metric that has been turned
/// off once remembers a zero. Re-enabling it must start from the metric's own
/// default rather than from that zero, or the toggle immediately unselects
/// itself and writes another zero to the server.
@MainActor
final class MetricTrackingTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var shared: SharedStore!
    private var queueURL: URL!
    private var suiteName: String!
    private var sessionStore: KeychainSessionStore!

    private let steps = MetricCatalogue.steps

    override func setUp() async throws {
        try await super.setUp()
        RecapStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-metrictracking-\(UUID().uuidString).json")
        suiteName = "peard-metrictracking-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        shared.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-metrictracking-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: RecapStubProtocol.makeSession()
        )
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: "pair1", health: DisabledHealthMetrics())
    }

    override func tearDown() async throws {
        for suffix in ["", ".inbox", ".cache"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: queueURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        RecapStubProtocol.reset()
        model = nil
        app = nil
        shared = nil
        try await super.tearDown()
    }

    /// The reported bug: on, off, on leaves it on, at the metric's default goal.
    func testTurningAMetricOffAndOnAgainLeavesItOn() {
        model.setMetricTracked(true, definition: steps)
        XCTAssertTrue(model.isMetricTracked(steps))

        model.setMetricTracked(false, definition: steps)
        XCTAssertFalse(model.isMetricTracked(steps))

        model.setMetricTracked(true, definition: steps)
        XCTAssertTrue(model.isMetricTracked(steps), "re-enabling must not read the stored zero as a goal")
        XCTAssertEqual(model.metricGoal(for: steps), steps.defaultGoal)
    }

    /// A zero left in the store by an earlier build is "not tracked", not a
    /// goal of zero: the stepper and the toggle start from the default again.
    func testAZeroLeftInTheStoreIsTreatedAsUntracked() {
        shared.setMetricGoal(0, forMetric: steps.slug.rawValue, forConnection: "pair1")
        let reopened = HomeModel(app: app, pairID: "pair1", health: DisabledHealthMetrics())

        XCTAssertFalse(reopened.isMetricTracked(steps))
        XCTAssertEqual(reopened.metricGoal(for: steps), steps.defaultGoal)

        reopened.setMetricTracked(true, definition: steps)
        XCTAssertTrue(reopened.isMetricTracked(steps))
        XCTAssertEqual(reopened.metricGoal(for: steps), steps.defaultGoal)
    }

    /// The goal is written through to the store, so a new day's model remembers
    /// what this one chose.
    func testTheGoalSurvivesARestart() {
        model.setMetricTracked(true, definition: steps)

        let reopened = HomeModel(app: app, pairID: "pair1", health: DisabledHealthMetrics())

        XCTAssertTrue(reopened.isMetricTracked(steps))
        XCTAssertEqual(reopened.metricGoal(for: steps), steps.defaultGoal)
    }

    /// Per-person tracking (#411): having my own goal is what counts for the
    /// settings toggle, not whether the connection tracks it. With no goal set I
    /// do not track it myself even if a partner does.
    func testTrackingByMeFollowsMyOwnGoalNotTheConnection() {
        XCTAssertFalse(model.isMetricTrackedByMe(steps))

        model.setMetricTracked(true, definition: steps)
        XCTAssertTrue(model.isMetricTrackedByMe(steps))

        model.setMetricTracked(false, definition: steps)
        XCTAssertFalse(model.isMetricTrackedByMe(steps))
    }

    /// `healthCanFill` reflects the provider: a device with no Health support
    /// (iPad / the disabled stub) cannot fill the metric, so settings offers no
    /// Health connect.
    func testHealthCanFillFollowsTheProvider() {
        XCTAssertFalse(model.healthCanFill(steps), "the disabled provider supports nothing")

        let withHealth = HomeModel(app: app, pairID: "pair1", health: StubHealthMetrics())
        XCTAssertTrue(withHealth.healthCanFill(steps))
    }

    /// The reported bug's fix: a member joining a metric gets their Health
    /// authorisation asked for, and on a grant their total is pushed straight
    /// away rather than waiting for the next foreground refresh.
    func testEnablingHealthSyncAsksForAuthAndPushesImmediately() async {
        HealthStubProtocol.reset()
        let health = StubHealthMetrics()
        health.totals = [steps.slug: 8200]

        let healthApp = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: HealthStubProtocol.makeSession()
        )
        await healthApp.attachSendQueue()
        let healthModel = HomeModel(app: healthApp, pairID: "pair1", health: health)
        // This member joins the metric for themselves.
        healthModel.setMetricTracked(true, definition: steps)

        await healthModel.enableHealthSync(for: steps)

        XCTAssertTrue(health.authorised.contains(steps.slug), "joining must ask for Health access")
        let pushed = HealthStubProtocol.dayPuts.contains {
            ($0["amount"] as? NSNumber)?.intValue == 8200
        }
        XCTAssertTrue(pushed, "a grant must push today's total straight away")
    }
}
