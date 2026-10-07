import XCTest
@testable import Peard
import PeardCore
import SwiftUI

/// Per-person water targets shared across a connection (#335), as `HomeModel`
/// wires them: a stepper echoes locally and is sent to the server as the user's
/// own, the recap brings everybody's back, and an older server leaves the
/// device-local behaviour exactly as it was.
///
/// Uses the recap suite's stub session, which also answers and records the
/// target route. Each test has a shared store of its own.
@MainActor
final class PerPersonWaterTargetFlowTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queueURL: URL!
    private var suiteName: String!
    private var sessionStore: KeychainSessionStore!
    private var store: SharedStore!

    private let gb = Locale(identifier: "en_GB")

    override func setUp() async throws {
        try await super.setUp()
        RecapStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-perperson-\(UUID().uuidString).json")
        suiteName = "peard-perperson-\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        store.recordPrivacyConsent()
        store.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-perperson-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: store,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: RecapStubProtocol.makeSession()
        )
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: "pair1")
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
        store = nil
        try await super.tearDown()
    }

    /// Polls for something that happens on a detached task, rather than sleeping
    /// for a guess at how long it takes.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: Writing your own

    func testMovingAStepperSendsTheUsersOwnTargets() async {
        model.updateWaterConfig {
            $0.setRecommended(2500)
            $0.setMinimum(1200)
        }
        await eventually { RecapStubProtocol.targetPosts.count >= 1 && RecapStubProtocol.recapRequests >= 1 }

        let last = RecapStubProtocol.targetPosts.last
        XCTAssertEqual(last?["pair"] as? String, "pair1")
        XCTAssertEqual(last?["minimum"] as? Int, 1200)
        XCTAssertEqual(last?["recommended"] as? Int, 2500)
        XCTAssertNil(last?["user"], "the server takes the user from the session")
    }

    func testTheStepperEchoesBeforeTheServerAnswers() {
        model.updateWaterConfig { $0.setRecommended(3000) }

        XCTAssertEqual(model.waterConfig.recommended, 3000, "no await between the tap and the new number")
        XCTAssertEqual(store.waterConfig(forConnection: "pair1").recommended, 3000)
    }

    func testAChangeIsFollowedByAFreshRecap() async {
        RecapStubProtocol.body = #"{"total":1}"#
        model.updateWaterConfig { $0.setRecommended(3000) }

        await eventually { RecapStubProtocol.recapRequests >= 1 }

        XCTAssertEqual(RecapStubProtocol.recapRequests, 1)
        XCTAssertEqual(RecapStubProtocol.lastRecapQuery("water_target"), "3000", "the fallback for old apps still goes up")
    }

    func testSizesAndTheSwitchStayOnTheDevice() async {
        model.updateWaterConfig {
            $0.addPreset(250)
            $0.isEnabled = false
        }
        await settle()

        XCTAssertTrue(RecapStubProtocol.targetPosts.isEmpty)
    }

    func testAQuickRunOfTapsEndsOnTheLastNumber() async {
        for ml in [2100, 2200, 2300, 2400] {
            model.updateWaterConfig { $0.setRecommended(ml) }
        }
        await eventually { (RecapStubProtocol.targetPosts.last?["recommended"] as? Int) == 2400 }

        XCTAssertEqual(RecapStubProtocol.targetPosts.last?["recommended"] as? Int, 2400)
        let sent = RecapStubProtocol.targetPosts.compactMap { $0["recommended"] as? Int }
        XCTAssertEqual(sent, sent.sorted(), "pushed in the order they were made")
    }

    // MARK: Reading everybody's

    func testYourStoredTargetIsAdoptedFromTheRecap() async {
        RecapStubProtocol.body = #"""
        {"total":1,"water_targets":[{"user":"me","minimum":1000,"recommended":3200},
                                    {"user":"ari","minimum":0,"recommended":2000}]}
        """#

        await model.refreshRecap()

        XCTAssertEqual(model.waterConfig.recommended, 3200)
        XCTAssertEqual(model.waterConfig.minimum, 1000)
        XCTAssertEqual(store.waterConfig(forConnection: "pair1").recommended, 3200, "kept for the next launch")
        XCTAssertTrue(RecapStubProtocol.targetPosts.isEmpty, "adopting is not a write")
    }

    func testThePartnersGoalIsAvailableToShow() async {
        RecapStubProtocol.body = #"""
        {"water_targets":[{"user":"me","minimum":1000,"recommended":2500},
                          {"user":"ari","minimum":900,"recommended":2000},
                          {"user":"sam","minimum":0,"recommended":0}]}
        """#

        await model.refreshRecap()

        XCTAssertEqual(model.otherWaterGoals, [WaterGoal(label: PartnerLabel.fallback, ml: 2000)])
        XCTAssertEqual(
            MomentBreakdownCopy.waterGoals(yours: 2500, others: [WaterGoal(label: "Ari", ml: 2000)], locale: gb),
            "Your goal 2,500 ml · Ari 2,000 ml"
        )
    }

    func testTheGoalsLineIsJustYoursWhenNobodyElseSetOne() {
        XCTAssertEqual(MomentBreakdownCopy.waterGoals(yours: 2000, others: [], locale: gb), "Your goal 2,000 ml")
    }

    func testTheTalliesSectionNamesBothGoals() {
        let section = WaterTodaySection(
            tallies: model.momentTallies,
            config: WaterConfig(minimum: 1000, recommended: 2500),
            otherGoals: [WaterGoal(label: "Ari", ml: 2000)],
            mineLabel: "You",
            othersLabel: "Ari"
        )

        XCTAssertEqual(section.goalsLine(locale: gb), "Your goal 2,500 ml · Ari 2,000 ml")
    }

    func testProgressIsTheUsersOwnDay() {
        XCTAssertEqual(model.waterProgress.ml, model.momentTallies.waterTodayMine)
        XCTAssertEqual(model.waterProgress.recommended, model.waterConfig.recommended)
    }

    // MARK: Older servers

    func testAServerWithoutTargetsLeavesTheLocalOnesStanding() async {
        model.updateWaterConfig { $0.setRecommended(2800) }
        await eventually { RecapStubProtocol.targetPosts.count >= 1 }
        RecapStubProtocol.body = #"{"total":3}"#

        await model.refreshRecap()

        XCTAssertNil(model.recap?.waterTargets)
        XCTAssertEqual(model.waterConfig.recommended, 2800)
        XCTAssertEqual(model.otherWaterGoals, [])
    }

    func testARouteThatIs404KeepsTheTargetOnTheDevice() async {
        RecapStubProtocol.targetStatus = 404
        model.updateWaterConfig { $0.setRecommended(2800) }
        await eventually { RecapStubProtocol.targetPosts.count >= 1 }
        await settle()

        XCTAssertEqual(model.waterConfig.recommended, 2800)
        XCTAssertEqual(RecapStubProtocol.targetPosts.count, 1, "not retried against a server that has no route")
    }

    // MARK: Upgrading, and failing

    /// Somebody who set a goal before goals were shared keeps it: with none stored
    /// on the server, the phone's is sent up.
    func testALocalGoalIsSentUpWhenTheServerHasNone() async {
        store.setWaterConfig(WaterConfig(minimum: 1200, recommended: 2600), forConnection: "pair1")
        model = HomeModel(app: app, pairID: "pair1")
        RecapStubProtocol.body = #"{"water_targets":[{"user":"me","minimum":0,"recommended":0}]}"#

        await model.refreshRecap()
        await eventually { RecapStubProtocol.targetPosts.count >= 1 }

        XCTAssertEqual(RecapStubProtocol.targetPosts.last?["recommended"] as? Int, 2600)
        XCTAssertEqual(RecapStubProtocol.targetPosts.last?["minimum"] as? Int, 1200)
        XCTAssertEqual(model.waterConfig.recommended, 2600)
    }

    func testNothingIsSentUpWhenThePhoneHasOnlyTheDefaults() async {
        RecapStubProtocol.body = #"{"water_targets":[{"user":"me","minimum":0,"recommended":0}]}"#

        await model.refreshRecap()
        await settle()

        XCTAssertTrue(RecapStubProtocol.targetPosts.isEmpty)
        XCTAssertTrue(model.waterConfig.hasStandardTargets)
    }

    /// A write that failed has to survive the next recap, which still carries the
    /// server's older number. The user's edit wins, and is sent again.
    func testAFailedWriteIsNotOverwrittenByTheServersOlderCopy() async {
        RecapStubProtocol.targetStatus = 500
        model.updateWaterConfig { $0.setRecommended(2800) }
        await eventually { RecapStubProtocol.targetPosts.count >= 1 }
        await settle()
        XCTAssertEqual(model.waterConfig.recommended, 2800)

        RecapStubProtocol.targetStatus = 200
        RecapStubProtocol.body = #"{"water_targets":[{"user":"me","minimum":1500,"recommended":2000}]}"#
        await model.refreshRecap()
        await eventually { RecapStubProtocol.targetPosts.count >= 2 }

        XCTAssertEqual(model.waterConfig.recommended, 2800, "the edit was not lost")
        XCTAssertEqual(RecapStubProtocol.targetPosts.last?["recommended"] as? Int, 2800, "and was sent again")
    }
}
