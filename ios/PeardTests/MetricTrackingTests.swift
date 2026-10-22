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
}
