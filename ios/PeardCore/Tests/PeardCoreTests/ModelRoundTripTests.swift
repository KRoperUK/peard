import XCTest
@testable import PeardCore

/// Requirement 4.7, 4.8 — unknown values survive and encoding round-trips.
final class ModelRoundTripTests: XCTestCase {
    private let decoder = JSONDecoder.peard
    private let encoder: JSONEncoder = {
        // Key order is unspecified for dictionaries, so sort it to make the
        // byte comparison below meaningful.
        let encoder = JSONEncoder.peard
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// encode → decode → encode produces the same bytes as the first encode.
    private func assertRoundTrips<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let first = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: first)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(decoded, value, "decoded value differs", file: file, line: line)
        XCTAssertEqual(
            String(decoding: second, as: UTF8.self),
            String(decoding: first, as: UTF8.self),
            "re-encode differs",
            file: file,
            line: line
        )
    }

    private var sampleDate: Date {
        PeardDate.parse("2026-07-28 21:30:15.250Z")!
    }

    // MARK: Open enums

    func testOpenEnumsPreserveUnknownValues() throws {
        XCTAssertEqual(PostType(rawValue: "sticker").rawValue, "sticker")
        XCTAssertEqual(MemberRole(rawValue: "admin").rawValue, "admin")
        XCTAssertEqual(ReactionKind(rawValue: "shrug").rawValue, "shrug")
        XCTAssertEqual(FeedState(rawValue: "degraded").rawValue, "degraded")

        XCTAssertEqual(PostType(rawValue: "photo"), .photo)
        XCTAssertEqual(ReactionKind(rawValue: "plus_one"), .plusOne)
        XCTAssertEqual(FeedState(rawValue: "unpaired"), .unpaired)
    }

    func testUnknownEnumEncodesOriginalString() throws {
        let json = try encoder.encode(PostType(rawValue: "sticker"))
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "\"sticker\"")
    }

    func testKnownReactionKindsAreTheThreeSupported() {
        XCTAssertEqual(ReactionKind.allCases.map(\.rawValue), ["cheers", "plus_one", "heart"])
        XCTAssertEqual(ReactionKind.allCases.map(\.emoji), ["🍻", "👏", "❤️"])
    }

    // MARK: Records

    func testPostRoundTrips() throws {
        try assertRoundTrips(Post(
            id: "p1", pair: "pair1", author: "user1", type: .event,
            eventKind: .beer, note: "cheers", media: nil, created: sampleDate
        ))
        try assertRoundTrips(Post(
            id: "p2", pair: "pair1", author: "user2", type: .photo,
            eventKind: nil, note: "", media: "shot.jpg", created: sampleDate
        ))
        try assertRoundTrips(Post(
            id: "p3", pair: "pair1", author: "user2", type: .unknown("sticker"),
            eventKind: EventKind(rawValue: "wine"), note: nil, media: nil, created: sampleDate
        ))
    }

    func testPostDecodesServerPayload() throws {
        let json = Data("""
        {"id":"abc","collectionId":"x","collectionName":"posts","pair":"pair1","author":"user1",
         "type":"event","event_kind":"beer","note":"","media":"","created":"2026-07-28 21:30:15.250Z",
         "updated":"2026-07-28 21:30:15.250Z"}
        """.utf8)

        let post = try decoder.decode(Post.self, from: json)

        XCTAssertEqual(post.id, "abc")
        XCTAssertEqual(post.type, .event)
        XCTAssertEqual(post.eventKind, .beer)
        XCTAssertNil(post.displayNote)
        XCTAssertFalse(post.hasMedia)
        XCTAssertEqual(post.created, sampleDate)
    }

    func testPostMediaThumbnailPath() throws {
        let post = Post(id: "abc", pair: "p", author: "u", type: .photo, media: "my shot.jpg", created: sampleDate)
        XCTAssertEqual(post.mediaThumbnailPath(), "/api/files/posts/abc/my%20shot.jpg?thumb=512x512")

        let eventPost = Post(id: "abc", pair: "p", author: "u", type: .event, created: sampleDate)
        XCTAssertNil(eventPost.mediaThumbnailPath())
    }

    /// A row written before the server gained its `created` field must not fail
    /// the whole list decode.
    func testPostWithoutTimestampDecodesAsDistantPast() throws {
        let missing = Data(#"{"id":"a","pair":"p","author":"u","type":"event"}"#.utf8)
        let empty = Data(#"{"id":"a","pair":"p","author":"u","type":"event","created":""}"#.utf8)

        for json in [missing, empty] {
            let post = try decoder.decode(Post.self, from: json)
            XCTAssertEqual(post.created, .distantPast)
            XCTAssertFalse(post.hasTimestamp)
        }

        let normal = try decoder.decode(
            Post.self,
            from: Data(#"{"id":"a","pair":"p","author":"u","type":"event","created":"2026-07-28 21:30:15.250Z"}"#.utf8)
        )
        XCTAssertTrue(normal.hasTimestamp)
    }

    func testPostListSurvivesOneUntimestampedRow() throws {
        let json = Data("""
        {"items":[
          {"id":"a","pair":"p","author":"u","type":"event","created":"2026-07-28 21:30:15.250Z"},
          {"id":"b","pair":"p","author":"u","type":"event","created":""}
        ]}
        """.utf8)

        let list = try decoder.decode(RecordList<Post>.self, from: json)

        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items.map(\.hasTimestamp), [true, false])
    }

    func testWidgetFeedPostWithoutTimestampDecodesAsNil() throws {
        let feed = try decoder.decode(WidgetFeed.self, from: Data("""
        {"state":"ok","partner":{"name":"Ada"},"counts":{"beer":0,"loo":0},
         "post":{"id":"p","type":"event","event_kind":"beer","note":"","created":"","media_url":"","author":"Ada"}}
        """.utf8))

        XCTAssertNil(try XCTUnwrap(feed.post).created)
    }

    func testPairMemberRoundTrips() throws {
        try assertRoundTrips(PairMember(id: "m1", pair: "pair1", user: "user1", role: .owner))
        try assertRoundTrips(PairMember(
            id: "m2", pair: "pair1", user: "user2", role: .unknown("guest"),
            expand: .init(user: UserRecord(id: "user2", email: "a@b.c", displayName: "Ada"))
        ))
    }

    func testReactionAndDeviceRoundTrip() throws {
        try assertRoundTrips(Reaction(id: "r1", post: "p1", user: "u1", kind: .cheers))
        try assertRoundTrips(Reaction(id: "r2", post: "p1", user: "u1", kind: .unknown("shrug")))
        try assertRoundTrips(Device(id: "d1", user: "u1", platform: "ios", pushToken: "abc123"))
    }

    func testDeviceUsesSnakeCasePushToken() throws {
        let json = try encoder.encode(Device(id: "d1", user: "u1", platform: "ios", pushToken: "abc"))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"push_token\":\"abc\""))
    }

    /// The message carries the https link, not the server's `deep_link`. The
    /// server still sends `peard://pair/{code}` and the model still decodes it —
    /// what changed is which of the two goes into a message somebody else
    /// receives, because a custom scheme is "Safari cannot open the page" to
    /// anybody without the app.
    func testPairInviteRoundTripsAndBuildsShareMessage() throws {
        let invite = PairInvite(code: "AB12CD", expires: sampleDate, deepLink: "peard://pair/AB12CD")
        try assertRoundTrips(invite)
        XCTAssertEqual(invite.shareMessage, "Pear up with me on Pear'd! Code: AB12CD\nhttps://peard.kroper.uk/c/AB12CD")
    }

    func testWidgetFeedRoundTrips() throws {
        try assertRoundTrips(WidgetFeed(state: .unpaired))
        try assertRoundTrips(WidgetFeed(
            state: .ok,
            partner: .init(name: "Ada"),
            counts: .init(beer: 2, loo: 3),
            post: .init(
                id: "p1", type: .event, eventKind: .beer, note: "cheers",
                created: sampleDate, mediaURL: "", author: "Ada"
            )
        ))
        try assertRoundTrips(WidgetFeed(
            state: .unknown("degraded"),
            partner: .init(name: "Ada"),
            counts: .init(beer: 0, loo: 0),
            post: .init(
                id: "p2", type: .photo, eventKind: EventKind(rawValue: ""), note: "",
                created: sampleDate, mediaURL: "http://host/file.jpg", author: "Ada"
            )
        ))
    }

    func testWidgetFeedDecodesServerPayload() throws {
        let json = Data("""
        {"state":"ok","partner":{"name":"Ada"},"counts":{"beer":1,"loo":2},
         "post":{"id":"p1","type":"photo","event_kind":"","note":"hi",
                 "created":"2026-07-28 21:30:15.250Z",
                 "media_url":"http://127.0.0.1:8090/api/files/posts/p1/x.jpg?thumb=512x512",
                 "author":"Ada"}}
        """.utf8)

        let feed = try decoder.decode(WidgetFeed.self, from: json)

        XCTAssertEqual(feed.state, .ok)
        XCTAssertEqual(feed.partnerName, "Ada")
        XCTAssertEqual(feed.beerCount, 1)
        XCTAssertEqual(feed.looCount, 2)
        XCTAssertTrue(try XCTUnwrap(feed.post).hasMedia)
        XCTAssertEqual(try XCTUnwrap(feed.post).displayNote, "hi")
    }

    func testWidgetFeedUnpairedPayloadHasNoPartnerOrCounts() throws {
        let feed = try decoder.decode(WidgetFeed.self, from: Data(#"{"state":"unpaired"}"#.utf8))
        XCTAssertEqual(feed.state, .unpaired)
        XCTAssertEqual(feed.partnerName, "Partner")
        XCTAssertEqual(feed.beerCount, 0)
        XCTAssertNil(feed.post)
    }

    func testAuthResponseDecodesUserRecord() throws {
        let json = Data("""
        {"token":"tok","record":{"id":"u1","email":"a@b.c","display_name":"Ada","verified":true}}
        """.utf8)

        let response = try decoder.decode(AuthResponse.self, from: json)

        XCTAssertEqual(response.token, "tok")
        XCTAssertEqual(response.record.id, "u1")
        XCTAssertEqual(response.record.displayName, "Ada")
    }

    func testWidgetFeedDecodesConnectionContextAndGeneralisedTallies() throws {
        let json = Data("""
        {"state":"ok","partner":{"name":"Sam"},
         "connection":{"id":"pair1","name":"Flatmates","member_count":4,"is_group":true},
         "counts":{"beer":2,"loo":1},
         "tallies":[{"kind":"beer","emoji":"🍺","label":"Beer","count":2},
                    {"kind":"dog_walk","emoji":"🐕","label":"Dog walk","count":1}],
         "post":{"id":"p1","type":"event","event_kind":"dog_walk","emoji":"🐕","label":"Dog walk",
                 "note":"round the park","created":"2026-07-28 10:00:00.000Z","media_url":"","author":"Sam"}}
        """.utf8)

        let feed = try decoder.decode(WidgetFeed.self, from: json)

        XCTAssertTrue(feed.isGroup)
        XCTAssertEqual(feed.groupName, "Flatmates")
        XCTAssertEqual(feed.connection?.memberCount, 4)
        XCTAssertEqual(feed.displayTallies.map(\.kind.rawValue), ["beer", "dog_walk"])
        XCTAssertEqual(feed.displayTallies.last?.emoji, "🐕")
        // A custom kind the client has no catalogue for still draws correctly,
        // because the server resolved it.
        XCTAssertEqual(feed.post?.displayEmoji, "🐕")
        XCTAssertEqual(feed.post?.displayLabel, "Dog walk")
        XCTAssertFalse(feed.post?.hasMedia ?? true)
    }

    func testWidgetFeedFallsBackToLegacyCountsWhenTalliesAreAbsent() throws {
        let json = Data("""
        {"state":"ok","partner":{"name":"Sam"},"counts":{"beer":3,"loo":0},
         "post":{"id":"p1","type":"event","event_kind":"beer","created":"2026-07-28 10:00:00.000Z"}}
        """.utf8)

        let feed = try decoder.decode(WidgetFeed.self, from: json)

        XCTAssertFalse(feed.isGroup)
        XCTAssertNil(feed.groupName)
        XCTAssertEqual(feed.displayTallies.map(\.kind.rawValue), ["beer"], "zero counts are omitted")
        XCTAssertEqual(feed.displayTallies.first?.count, 3)
        // No server-side emoji: the local catalogue supplies it.
        XCTAssertEqual(feed.post?.displayEmoji, "🍺")
        XCTAssertEqual(feed.post?.displayLabel, "Beer")
    }

    func testPairInviteDistinguishesAGroupInviteFromANewConnection() throws {
        let group = try decoder.decode(PairInvite.self, from: Data("""
        {"code":"ABC123","expires":"2026-08-04 10:00:00.000Z","deep_link":"peard://pair/ABC123","pair":"pair1"}
        """.utf8))
        let fresh = try decoder.decode(PairInvite.self, from: Data("""
        {"code":"ABC123","expires":"2026-08-04 10:00:00.000Z","deep_link":"peard://pair/ABC123"}
        """.utf8))

        XCTAssertTrue(group.isGroupInvite)
        XCTAssertTrue(group.shareMessage.contains("Join my group"))
        XCTAssertFalse(fresh.isGroupInvite)
        XCTAssertTrue(fresh.shareMessage.contains("Pear up with me"))
        XCTAssertTrue(fresh.shareMessage.contains("ABC123"))
    }
}
