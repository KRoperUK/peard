import XCTest
@testable import PeardCore

/// Reading a notification's payload, and deciding whether it is about the
/// connection somebody is already looking at.
final class MomentPushTests: XCTestCase {
    func testAMomentAlertParses() {
        let push = MomentPush(userInfo: ["post_id": "post1", "pair_id": "pair1", "event_kind": "beer"])

        XCTAssertEqual(push, MomentPush(postID: "post1", pairID: "pair1", eventKind: .beer))
    }

    func testAPhotoOrReactionAlertHasNoKind() {
        XCTAssertNil(MomentPush(userInfo: ["post_id": "post1", "pair_id": "pair1"])?.eventKind)
        XCTAssertNil(MomentPush(userInfo: ["post_id": "post1", "pair_id": "pair1", "event_kind": ""])?.eventKind)
    }

    /// The recap names a connection but no post; an alert from a server older
    /// than this names a post but may name no connection. Neither is a moment
    /// the screen can fold in.
    func testAnAlertWithoutAPostOrAConnectionDoesNotParse() {
        XCTAssertNil(MomentPush(userInfo: ["pair_id": "pair1"]))
        XCTAssertNil(MomentPush(userInfo: ["post_id": "post1"]))
        XCTAssertNil(MomentPush(userInfo: ["post_id": "", "pair_id": "pair1"]))
        XCTAssertNil(MomentPush(userInfo: [:]))
    }

    func testItIsForTheConnectionOnScreenOnlyWhenTheyMatch() {
        let push = MomentPush(postID: "post1", pairID: "pair1")

        XCTAssertTrue(push.isFor(connectionOnScreen: "pair1"))
        XCTAssertFalse(push.isFor(connectionOnScreen: "pair2"))
        XCTAssertFalse(push.isFor(connectionOnScreen: nil), "no connection on screen — the connections list, sign-in")
        XCTAssertFalse(push.isFor(connectionOnScreen: ""))
    }
}
