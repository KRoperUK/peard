import XCTest
@testable import PeardCore

/// The avatar layer is mostly derivation, and the derivations are the part that
/// can be wrong in a way nobody notices: a colour that changes between launches,
/// a path missing its thumb, a group borrowing a face it should not.
final class AvatarTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8090")!

    // MARK: Paths

    func testPathIncludesTheRequestedThumb() {
        let avatar = Avatar(
            owner: .users,
            recordID: "abc123",
            filename: "avatar_x7Kq2.jpg",
            placeholder: .make(name: "Ari", key: "abc123")
        )
        XCTAssertEqual(avatar.path(thumb: .small), "/api/files/users/abc123/avatar_x7Kq2.jpg?thumb=128x128")
        XCTAssertEqual(avatar.path(thumb: .large), "/api/files/users/abc123/avatar_x7Kq2.jpg?thumb=512x512")
        XCTAssertEqual(avatar.path(thumb: nil), "/api/files/users/abc123/avatar_x7Kq2.jpg")
    }

    func testPairOwnerUsesThePairsCollection() {
        let avatar = Avatar(
            owner: .pairs,
            recordID: "pair1",
            filename: "group.png",
            placeholder: .make(name: "Flatmates", key: "pair1", isGroup: true)
        )
        XCTAssertEqual(avatar.path(), "/api/files/pairs/pair1/group.png?thumb=128x128")
    }

    func testEmptyFilenameIsTreatedAsNoPhoto() {
        // The server sends "" for an unset file field rather than omitting it, so
        // an empty string has to mean "no photo" or every placeholder would try to
        // fetch `/api/files/users/{id}/`.
        let avatar = Avatar(owner: .users, recordID: "u1", filename: "", placeholder: .make(name: "Bo", key: "u1"))
        XCTAssertFalse(avatar.hasImage)
        XCTAssertNil(avatar.path())
        XCTAssertNil(avatar.url(base: base))
    }

    func testFilenameWithSpaceIsPercentEncoded() {
        let avatar = Avatar(
            owner: .users,
            recordID: "u1",
            filename: "my photo.jpg",
            placeholder: .make(name: "Bo", key: "u1")
        )
        XCTAssertEqual(avatar.path(thumb: nil), "/api/files/users/u1/my%20photo.jpg")
        XCTAssertNotNil(avatar.url(base: base, thumb: nil), "an unescaped space produces a URL that will not build")
    }

    func testURLDoesNotDoubleTheSlashWhenTheBaseHasOne() {
        let avatar = Avatar(
            owner: .users,
            recordID: "u1",
            filename: "a.jpg",
            placeholder: .make(name: "Bo", key: "u1")
        )
        let trailing = URL(string: "https://peard.kroper.uk/")!
        XCTAssertEqual(
            avatar.url(base: trailing, thumb: nil)?.absoluteString,
            "https://peard.kroper.uk/api/files/users/u1/a.jpg"
        )
    }

    // MARK: Initials

    func testInitialsTakeTheFirstLetterOfTheFirstTwoWords() {
        XCTAssertEqual(AvatarInitials.derive(from: "Ari Bloom"), "AB")
        XCTAssertEqual(AvatarInitials.derive(from: "ari bloom stone"), "AB")
        XCTAssertEqual(AvatarInitials.derive(from: "Bo"), "B")
        XCTAssertEqual(AvatarInitials.derive(from: "curl-crew"), "CC")
        XCTAssertEqual(AvatarInitials.derive(from: "  spaced   out  "), "SO")
    }

    func testInitialsFallBackToAPearWhenThereIsNothingUsable() {
        XCTAssertEqual(AvatarInitials.derive(from: ""), "🍐")
        XCTAssertEqual(AvatarInitials.derive(from: "   "), "🍐")
    }

    func testInitialsKeepAWholeGrapheme() {
        // A flag is several scalars. Slicing by scalar would render half of one,
        // which draws as a stray letter or an empty box.
        XCTAssertEqual(AvatarInitials.derive(from: "🇬🇧 Team"), "🇬🇧T")
    }

    // MARK: Colours

    func testColourIndexIsStableAcrossCalls() {
        let first = AvatarPalette.index(for: "user-record-id")
        let second = AvatarPalette.index(for: "user-record-id")
        XCTAssertEqual(first, second)
    }

    func testColourIndexIsWithinThePalette() {
        for key in ["", "a", "user1", "pair-abcdefghijklmno", "🍐"] {
            let index = AvatarPalette.index(for: key)
            XCTAssertTrue(
                AvatarPalette.colours.indices.contains(index),
                "index \(index) for key \(key) is outside the palette"
            )
        }
    }

    func testColourIndexIsNotSwiftsSeededHash() {
        // The point of FNV-1a here is that the value is a property of the string
        // rather than of the process. This pins the expected index for a known
        // key: if somebody swaps in `hashValue`, this fails on the second run.
        XCTAssertEqual(AvatarPalette.index(for: "abc123"), fnvIndex(for: "abc123"))
    }

    private func fnvIndex(for key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return Int(hash % UInt64(AvatarPalette.colours.count))
    }

    func testDifferentKeysUseTheWholePalette() {
        // Not a uniformity claim — just that a handful of realistic ids do not all
        // collapse onto one colour, which would make the rail useless.
        let keys = (0..<40).map { "record\($0)" }
        let indices = Set(keys.map(AvatarPalette.index(for:)))
        XCTAssertGreaterThan(indices.count, 3, "40 ids produced only \(indices.count) colours")
    }

    // MARK: Connection avatars

    func testGroupWithItsOwnPhotoUsesThePairsCollection() {
        let connection = Connection(
            pair: "pair1",
            name: "Flatmates",
            memberCount: 3,
            members: [
                .init(user: "me", name: "Me", isYou: true),
                .init(user: "ari", name: "Ari", avatarFilename: "ari.jpg"),
                .init(user: "bo", name: "Bo"),
            ],
            avatarFilename: "group.jpg"
        )
        XCTAssertEqual(connection.avatar.owner, .pairs)
        XCTAssertEqual(connection.avatar.path(), "/api/files/pairs/pair1/group.jpg?thumb=128x128")
        XCTAssertTrue(connection.hasOwnAvatar)
        XCTAssertTrue(connection.avatar.placeholder.isGroup)
    }

    func testPairWithoutItsOwnPhotoBorrowsThePartners() {
        let connection = Connection(
            pair: "pair1",
            memberCount: 2,
            members: [
                .init(user: "me", name: "Me", isYou: true),
                .init(user: "ari", name: "Ari", avatarFilename: "ari.jpg"),
            ]
        )
        XCTAssertEqual(connection.avatar.owner, .users)
        XCTAssertEqual(connection.avatar.path(), "/api/files/users/ari/ari.jpg?thumb=128x128")
        XCTAssertFalse(connection.hasOwnAvatar, "borrowing a face is not the same as having one to remove")
    }

    func testGroupDoesNotBorrowAMembersPhoto() {
        // A group is not any one of its members. Borrowing would show a group of
        // twelve as whoever happens to be listed first.
        let connection = Connection(
            pair: "pair1",
            memberCount: 3,
            members: [
                .init(user: "me", name: "Me", isYou: true),
                .init(user: "ari", name: "Ari", avatarFilename: "ari.jpg"),
                .init(user: "bo", name: "Bo"),
            ]
        )
        XCTAssertFalse(connection.avatar.hasImage)
        XCTAssertTrue(connection.avatar.placeholder.isGroup)
    }

    func testPairWithoutAnyPhotoDrawsThePartnersInitials() {
        let connection = Connection(
            pair: "pair1",
            memberCount: 2,
            members: [
                .init(user: "me", name: "Me", isYou: true),
                .init(user: "ari", name: "Ari Bloom"),
            ]
        )
        XCTAssertFalse(connection.avatar.hasImage)
        // The title of an unnamed 1:1 is the partner's name.
        XCTAssertEqual(connection.avatar.placeholder.initials, "AB")
        XCTAssertFalse(connection.avatar.placeholder.isGroup)
    }

    func testColourFollowsTheRecordIDNotTheName() {
        let before = Connection(pair: "pair1", name: "Flatmates", memberCount: 3)
        let after = Connection(pair: "pair1", name: "The Best Flat", memberCount: 3)
        XCTAssertEqual(
            before.avatar.placeholder.colourIndex,
            after.avatar.placeholder.colourIndex,
            "renaming a group should not recolour it"
        )
    }

    // MARK: Decoding

    func testConnectionDecodesAvatarFilenames() throws {
        let json = """
        {"connections":[{"pair":"p1","name":"Flatmates","member_count":3,"avatar":"g.jpg","members":[
          {"user":"me","name":"Me","role":"owner","is_you":true,"avatar":""},
          {"user":"ari","name":"Ari","role":"member","is_you":false,"avatar":"a.png"}
        ]}]}
        """
        let list = try JSONDecoder.peard.decode(ConnectionList.self, from: Data(json.utf8))
        let connection = try XCTUnwrap(list.connections.first)
        XCTAssertEqual(connection.avatarFilename, "g.jpg")
        XCTAssertEqual(connection.members[1].avatarFilename, "a.png")
        XCTAssertFalse(connection.members[0].avatar.hasImage)
        XCTAssertTrue(connection.members[1].avatar.hasImage)
    }

    func testConnectionDecodesWithoutAvatarFields() throws {
        // A server predating the avatars migration omits them entirely. The
        // client has to keep working against it rather than failing to decode.
        let json = """
        {"connections":[{"pair":"p1","member_count":2,"members":[
          {"user":"me","name":"Me","role":"owner","is_you":true}
        ]}]}
        """
        let list = try JSONDecoder.peard.decode(ConnectionList.self, from: Data(json.utf8))
        let connection = try XCTUnwrap(list.connections.first)
        XCTAssertNil(connection.avatarFilename)
        XCTAssertFalse(connection.avatar.hasImage)
    }

    func testProfileDecodesAvatar() throws {
        let json = #"{"id":"u1","display_name":"Ari","email":"ari@example.com","avatar":"a.jpg"}"#
        let profile = try JSONDecoder.peard.decode(UserProfile.self, from: Data(json.utf8))
        XCTAssertTrue(profile.hasAvatar)
        XCTAssertEqual(profile.avatar.path(thumb: .large), "/api/files/users/u1/a.jpg?thumb=512x512")

        let bare = #"{"id":"u1","display_name":"Ari","email":"ari@example.com","avatar":""}"#
        let withoutPhoto = try JSONDecoder.peard.decode(UserProfile.self, from: Data(bare.utf8))
        XCTAssertFalse(withoutPhoto.hasAvatar)
        XCTAssertEqual(withoutPhoto.avatar.placeholder.initials, "A")
    }

    func testConnectionAvatarResponseDecodes() throws {
        let json = #"{"pair":"p1","avatar":"g.jpg"}"#
        let response = try JSONDecoder.peard.decode(ConnectionAvatar.self, from: Data(json.utf8))
        XCTAssertEqual(response.pair, "p1")
        XCTAssertEqual(response.avatarFilename, "g.jpg")
    }
}
