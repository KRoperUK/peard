import PeardCore
import UserNotifications
import XCTest
@testable import Peard

/// "Me too" and "Reply" on a moment's notification (issue #154): which alerts
/// offer them, and what answering one puts in the send queue.
@MainActor
final class NotificationActionTests: XCTestCase {
    private var app: AppModel!
    private var storeURL: URL!
    private var suiteName: String!
    private var shared: SharedStore!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-answers-\(UUID().uuidString).json")
        suiteName = "peard-answers-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        // Kept off, so answering queues without flushing: the flush would go
        // to whatever server this build points at.
        shared.clearPrivacyConsent()
        sessionStore = KeychainSessionStore(service: suiteName)
        sessionStore.clear()
        app = AppModel(
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: storeURL))
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        sessionStore = nil
        app = nil
        shared = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: Categories

    private func actions(in identifier: String) throws -> [UNNotificationAction] {
        let category = PushCoordinator.notificationCategories().first { $0.identifier == identifier }
        return try XCTUnwrap(category, "no \(identifier) category").actions
    }

    func testAMomentOffersMeTooAReplyAndTheReactions() throws {
        let actions = try actions(in: "MOMENT")

        XCTAssertEqual(actions.map(\.identifier), ["ME_TOO", "REPLY", "REACT_cheers", "REACT_plus_one", "REACT_heart"])
        XCTAssertTrue(actions[1] is UNTextInputNotificationAction, "a reply is typed")
    }

    /// A photo on its own, or a reply, has no moment to log back.
    func testAPostWithoutAMomentOffersNoMeToo() throws {
        let actions = try actions(in: "POST")

        XCTAssertEqual(actions.map(\.identifier), ["REPLY", "REACT_cheers", "REACT_plus_one", "REACT_heart"])
    }

    // MARK: Answering

    private let beer = MomentPush(postID: "post1", pairID: "pair1", eventKind: .beer)

    func testMeTooIsQueuedForTheSameConnection() async throws {
        try sessionStore.save(token: "token", userID: "me")
        let moment = try XCTUnwrap(NotificationAnswer.meToo.moment(for: beer, id: "answer1"))

        await app.answerFromNotification(moment)

        XCTAssertEqual(app.pendingSends, [PendingSend(
            id: "answer1", pairID: "pair1", authorID: "me", kind: .beer,
            emoji: "🍺", label: "Beer", queuedAt: moment.queuedAt
        )])
    }

    func testAReplyIsQueuedAsWords() async throws {
        try sessionStore.save(token: "token", userID: "me")
        let moment = try XCTUnwrap(NotificationAnswer.reply("enjoy!").moment(for: beer))

        await app.answerFromNotification(moment)

        let send = try XCTUnwrap(app.pendingSends.first)
        XCTAssertEqual(send.pairID, "pair1")
        XCTAssertEqual(send.postType, .note)
        XCTAssertEqual(send.note, "enjoy!")
        XCTAssertEqual(send.postFields["type"], "note")
    }

    func testNothingIsQueuedWhenSignedOut() async throws {
        let moment = try XCTUnwrap(NotificationAnswer.meToo.moment(for: beer))

        await app.answerFromNotification(moment)

        XCTAssertTrue(app.pendingSends.isEmpty)
    }
}
