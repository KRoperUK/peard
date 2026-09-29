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
}
