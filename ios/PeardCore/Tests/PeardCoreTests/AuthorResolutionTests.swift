import XCTest
@testable import PeardCore

/// Naming and drawing a moment's author, which the home screen and the timeline
/// both do and used to do differently.
final class AuthorResolutionTests: XCTestCase {
    private let oneToOne = Connection(
        pair: "pair1",
        members: [
            .init(user: "me", name: "Me", role: .owner, isYou: true),
            .init(user: "sam", name: "Sam Rivers", avatarFilename: "sam.jpg"),
        ]
    )

    private let group = Connection(
        pair: "pair2",
        name: "Flatmates",
        memberCount: 3,
        members: [
            .init(user: "me", name: "Me", role: .owner, isYou: true),
            .init(user: "ari", name: "Ari Bloom", avatarFilename: "ari.jpg"),
            .init(user: "bo", name: "Bo"),
        ]
    )

    private func label(_ userID: String, in connection: Connection?) -> String {
        Connection.authorLabel(for: userID, in: connection, signedInUserID: "me")
    }

    func testYourOwnMomentsAreYours() {
        XCTAssertEqual(label("me", in: oneToOne), "You")
        XCTAssertEqual(label("me", in: group), "You")
        // Before the connection list has loaded, too: the signed-in user is known
        // from the session, not the member list.
        XCTAssertEqual(label("me", in: nil), "You")
    }

    /// The whole name: the row truncates to its width, and VoiceOver reads the
    /// same string.
    func testAMemberIsNamedInFull() {
        XCTAssertEqual(label("sam", in: oneToOne), "Sam Rivers")
        XCTAssertEqual(label("ari", in: group), "Ari Bloom")
    }

    /// The rule the two screens disagreed on. Somebody who is not a member of a
    /// 1:1 can only be somebody who left, so the current partner is a different
    /// person and must not be credited with their moments.
    func testAFormerMemberOfAOneToOneIsNotNamedAfterTheCurrentPartner() {
        XCTAssertEqual(oneToOne.partnerName, "Sam Rivers")
        XCTAssertEqual(label("departed", in: oneToOne), PartnerLabel.unknown)
    }

    func testAFormerMemberOfAGroupIsNeutral() {
        XCTAssertEqual(label("departed", in: group), PartnerLabel.unknown)
    }

    func testAnAuthorBeforeTheConnectionLoadsIsNeutral() {
        XCTAssertEqual(label("sam", in: nil), PartnerLabel.unknown)
    }

    func testAMembersAvatarComesFromTheMemberList() {
        let avatar = Connection.authorAvatar(for: "ari", in: group)
        XCTAssertEqual(avatar.path(), "/api/files/users/ari/ari.jpg?thumb=128x128")
    }

    func testAMemberWithoutAPhotoDrawsTheirInitials() {
        let avatar = Connection.authorAvatar(for: "bo", in: group)
        XCTAssertFalse(avatar.hasImage)
        XCTAssertEqual(avatar.placeholder.initials, "B")
    }

    /// No photo to find, so no path to a file that would 404 — and the initials
    /// match the name the label gives the same author.
    func testAFormerMemberDrawsTheNeutralPlaceholder() {
        for connection in [oneToOne, group] {
            let avatar = Connection.authorAvatar(for: "departed", in: connection)
            XCTAssertFalse(avatar.hasImage)
            XCTAssertNil(avatar.path())
            XCTAssertEqual(avatar.placeholder.initials, AvatarInitials.derive(from: label("departed", in: connection)))
        }
    }

    func testAnAvatarBeforeTheConnectionLoadsIsStillDrawable() {
        let avatar = Connection.authorAvatar(for: "ari", in: nil)
        XCTAssertFalse(avatar.hasImage)
        XCTAssertFalse(avatar.placeholder.initials.isEmpty)
    }
}
