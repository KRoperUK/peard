import XCTest
@testable import Peard
import PeardCore

/// Who is offered the bin on a published moment, and what a failed removal
/// says. The bin used to show for every member and every failure blamed
/// permissions, including having no signal.
@MainActor
final class MomentRemovalTests: XCTestCase {
    private let kinds = [
        MomentKind(id: "rec-mine", pair: "p1", slug: EventKind(rawValue: "dog_walk"), emoji: "🐕", label: "Dog walk", createdBy: "me"),
        MomentKind(id: "rec-theirs", pair: "p1", slug: EventKind(rawValue: "gym"), emoji: "🏋️", label: "Gym", createdBy: "sam"),
        MomentKind(id: "rec-unknown", pair: "p1", slug: EventKind(rawValue: "tea"), emoji: "🍵", label: "Tea"),
    ]

    private func moment(_ recordID: String?) -> Moment {
        Moment(kind: EventKind(rawValue: "x"), emoji: "🐕", label: "X", origin: .custom(recordID: recordID))
    }

    // MARK: Who sees the bin

    func testTheCreatorCanRemoveTheirMoment() {
        XCTAssertTrue(HomeModel.canRemove(moment("rec-mine"), customKinds: kinds, userID: "me"))
    }

    func testAnotherMemberCannot() {
        XCTAssertFalse(HomeModel.canRemove(moment("rec-theirs"), customKinds: kinds, userID: "me"))
    }

    /// A record with no creator is nobody's to remove from here — the server
    /// would refuse it anyway.
    func testAMomentWithNoRecordedCreatorOffersNoBin() {
        XCTAssertFalse(HomeModel.canRemove(moment("rec-unknown"), customKinds: kinds, userID: "me"))
    }

    /// Signed out, the user id is empty: it must not match an empty creator.
    func testNobodySignedInOffersNoBin() {
        XCTAssertFalse(HomeModel.canRemove(moment("rec-unknown"), customKinds: kinds, userID: ""))
    }

    func testABuiltInOffersNoBin() {
        let beer = Moment(kind: .beer, emoji: "🍺", label: "Beer", origin: .builtin)
        XCTAssertFalse(HomeModel.canRemove(beer, customKinds: kinds, userID: "me"))
    }

    // MARK: What a failure says

    func testNoSignalSaysSo() {
        let alert = HomeModel.removalAlert(for: APIError.transport("The Internet connection appears to be offline."))
        XCTAssertEqual(alert?.message, "Couldn't reach Pear'd. Check your connection and try again.")
    }

    func testForbiddenBlamesPermissions() {
        let alert = HomeModel.removalAlert(for: APIError.server(status: 403, message: nil))
        XCTAssertEqual(alert?.message, "Only whoever added a moment can remove it.")
    }

    func testAnythingElseDoesNotBlamePermissions() {
        let alert = HomeModel.removalAlert(for: APIError.server(status: 500, message: nil))
        XCTAssertNotNil(alert)
        XCTAssertNotEqual(alert?.message, "Only whoever added a moment can remove it.")
    }

    func testACancelledRequestSaysNothing() {
        XCTAssertNil(HomeModel.removalAlert(for: APIError.cancelled))
    }
}
