import XCTest
@testable import PeardCore

/// A reaction tapped on a notification, as the request it makes.
final class NotificationReactionTests: XCTestCase {
    func testEveryKindRoundTripsThroughItsActionIdentifier() throws {
        for kind in ReactionKind.allCases {
            let identifier = NotificationReaction.actionIdentifier(for: kind)
            let reaction = try XCTUnwrap(NotificationReaction(actionIdentifier: identifier, postID: "post1"))
            XCTAssertEqual(reaction.kind, kind)
            XCTAssertEqual(reaction.postID, "post1")
        }
    }

    func testFieldsNameThePostTheUserAndTheKind() throws {
        let reaction = try XCTUnwrap(NotificationReaction(actionIdentifier: "REACT_heart", postID: "post1"))
        XCTAssertEqual(reaction.fields(userID: "me"), ["post": "post1", "user": "me", "kind": "heart"])
    }

    func testOtherActionsAreNotReactions() {
        XCTAssertNil(NotificationReaction(actionIdentifier: "ME_TOO", postID: "post1"))
        XCTAssertNil(NotificationReaction(actionIdentifier: "REPLY", postID: "post1"))
        XCTAssertNil(NotificationReaction(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", postID: "post1"))
        XCTAssertNil(NotificationReaction(actionIdentifier: "REACT_", postID: "post1"))
    }

    func testANotificationWithNoPostIsNotAReaction() {
        XCTAssertNil(NotificationReaction(actionIdentifier: "REACT_heart", postID: nil))
        XCTAssertNil(NotificationReaction(actionIdentifier: "REACT_heart", postID: ""))
    }

    // MARK: durable send (#341)

    private func reaction() throws -> NotificationReaction {
        try XCTUnwrap(NotificationReaction(actionIdentifier: "REACT_heart", postID: "post1"))
    }

    func testSendSucceedsFirstTry() async throws {
        let r = try reaction()
        var calls = 0
        let ok = await r.send(userID: "me", send: { fields in
            calls += 1
            XCTAssertEqual(fields, ["post": "post1", "user": "me", "kind": "heart"])
        }, sleep: { _ in })
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 1, "a reaction that lands on the first attempt is not retried")
    }

    func testSendRetriesAfterATransientFailureThenSucceeds() async throws {
        let r = try reaction()
        var calls = 0
        let ok = await r.send(userID: "me", send: { _ in
            calls += 1
            if calls < 3 { throw APIError.transport("offline") } // retryable
        }, sleep: { _ in })
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 3, "a transient failure is retried, not dropped as the old single attempt was")
    }

    func testSendGivesUpImmediatelyOnAPermanentFailure() async throws {
        let r = try reaction()
        var calls = 0
        let ok = await r.send(userID: "me", send: { _ in
            calls += 1
            throw APIError.server(status: 404, message: "post gone") // permanent
        }, sleep: { _ in })
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 1, "a permanent failure must not burn the retry budget")
    }

    func testSendFailsAfterExhaustingRetryableAttempts() async throws {
        let r = try reaction()
        var calls = 0
        let ok = await r.send(userID: "me", attempts: 3, send: { _ in
            calls += 1
            throw APIError.transport("still offline")
        }, sleep: { _ in })
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 3, "all attempts in the budget are used before giving up")
    }

    func testSendRefusesWithoutAUser() async throws {
        let r = try reaction()
        var calls = 0
        let ok = await r.send(userID: "", send: { _ in calls += 1 }, sleep: { _ in })
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 0)
    }
}
