import XCTest
@testable import PeardCore

/// The `unread` count `GET /api/peard/connections` reports, and how a client
/// decodes it.
///
/// The decoding rules matter more than they look: the rail draws this number
/// straight onto a face, so anything the decoder lets through — a missing field,
/// a negative — is something a user sees.
final class UnreadTests: XCTestCase {
    private func decode(_ json: String) throws -> Connection {
        try JSONDecoder.peard.decode(Connection.self, from: Data(json.utf8))
    }

    func testUnreadIsDecodedFromTheResponse() throws {
        let connection = try decode(#"{"pair":"p1","unread":4}"#)

        XCTAssertEqual(connection.unreadCount, 4)
        XCTAssertTrue(connection.hasUnread)
    }

    func testZeroUnreadIsNotUnread() throws {
        let connection = try decode(#"{"pair":"p1","unread":0}"#)

        XCTAssertEqual(connection.unreadCount, 0)
        XCTAssertFalse(connection.hasUnread)
    }

    /// A server predating read state omits the field entirely. That has to read
    /// as "nothing new" rather than as a decoding failure, or one old server
    /// would take the whole connection list down with it.
    func testAMissingFieldReadsAsNothingNew() throws {
        let connection = try decode(#"{"pair":"p1","name":"Flatmates"}"#)

        XCTAssertEqual(connection.unreadCount, 0)
        XCTAssertFalse(connection.hasUnread)
        XCTAssertEqual(connection.pair, "p1", "the rest of the connection must still decode")
    }

    /// Nothing should ever send one, but the badge renders the number directly,
    /// so a negative would draw "-1" on somebody's face.
    func testANegativeCountIsClampedToZero() throws {
        let connection = try decode(#"{"pair":"p1","unread":-3}"#)

        XCTAssertEqual(connection.unreadCount, 0)
        XCTAssertFalse(connection.hasUnread)
    }

    func testUnreadSurvivesARoundTrip() throws {
        let original = Connection(pair: "p1", name: "Flatmates", unreadCount: 7)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder.peard.decode(Connection.self, from: data)

        XCTAssertEqual(decoded.unreadCount, 7)
    }

    /// Muting silences the alert; it does not mean "stop telling me anything
    /// happened". The rail shows a count for a muted connection, and the model
    /// must not quietly suppress it.
    func testAMutedConnectionStillReportsItsCount() throws {
        let connection = try decode(#"{"pair":"p1","muted":true,"unread":2}"#)

        XCTAssertTrue(connection.isMuted)
        XCTAssertEqual(connection.unreadCount, 2)
        XCTAssertTrue(connection.hasUnread)
    }

    func testUnreadDefaultsToZeroWhenConstructedInCode() {
        XCTAssertEqual(Connection(pair: "p1").unreadCount, 0)
    }

    // MARK: Badge total

    func testBadgeSumsEveryConnection() {
        let connections = [
            Connection(pair: "p1", unreadCount: 2),
            Connection(pair: "p2", unreadCount: 3),
            Connection(pair: "p3", unreadCount: 0),
        ]

        XCTAssertEqual(connections.totalUnreadForBadge, 5)
    }

    /// The badge accompanies an alert a muted connection would not have
    /// produced, so counting it would put a number on the icon that opening
    /// anything cannot account for. The server's `unseenCount` excludes muted
    /// memberships for the same reason; these two disagreeing is the failure
    /// this guards.
    func testBadgeSkipsMutedConnections() {
        let connections = [
            Connection(pair: "p1", unreadCount: 2),
            Connection(pair: "p2", isMuted: true, unreadCount: 100),
        ]

        XCTAssertEqual(connections.totalUnreadForBadge, 2)
    }

    func testBadgeIsZeroWithNoConnections() {
        XCTAssertEqual([Connection]().totalUnreadForBadge, 0)
    }

    /// Reading everything has to take the badge to zero on its own. The whole
    /// point of setting it from the app is that iOS otherwise leaves whatever
    /// the last push put there until another one arrives.
    func testBadgeIsZeroOnceEverythingIsRead() {
        let connections = [
            Connection(pair: "p1", unreadCount: 0),
            Connection(pair: "p2", isMuted: true, unreadCount: 0),
        ]

        XCTAssertEqual(connections.totalUnreadForBadge, 0)
    }

    // MARK: Widget feed

    private func decodeFeed(_ json: String) throws -> WidgetFeed {
        try JSONDecoder.peard.decode(WidgetFeed.self, from: Data(json.utf8))
    }

    func testWidgetFeedDecodesUnread() throws {
        let feed = try decodeFeed(#"{"state":"ok","unread":3}"#)

        XCTAssertEqual(feed.unreadCount, 3)
        XCTAssertTrue(feed.hasUnread)
    }

    /// The trap this guards: `unreadCount` is not optional, and the JSON key is
    /// `unread`. Left to synthesised Codable it would look for "unreadCount",
    /// never find it, and fail the decode of the *whole* feed — the entire
    /// widget going blank in order to add a number to it. Any server that omits
    /// the field, old or new, must still render.
    func testWidgetFeedWithoutUnreadStillDecodes() throws {
        let feed = try decodeFeed(#"{"state":"ok","partner":{"name":"Sam"}}"#)

        XCTAssertEqual(feed.unreadCount, 0)
        XCTAssertFalse(feed.hasUnread)
        XCTAssertEqual(feed.partnerName, "Sam", "the rest of the feed must survive")
    }

    func testWidgetFeedClampsANegativeCount() throws {
        XCTAssertEqual(try decodeFeed(#"{"state":"ok","unread":-2}"#).unreadCount, 0)
    }

    /// The custom decoder has to keep decoding everything the synthesised one
    /// did; a field dropped from it would go silently missing.
    func testWidgetFeedStillDecodesItsOtherFields() throws {
        let json = """
        {"state":"ok","partner":{"name":"Sam"},
         "connection":{"id":"p1","name":"Flatmates","member_count":3,"is_group":true},
         "counts":{"beer":2,"loo":1},
         "post":{"id":"x","type":"event","event_kind":"beer","note":"pub"},
         "moments":[{"kind":"beer","emoji":"🍺","label":"Beer"}],
         "unread":1}
        """

        let feed = try decodeFeed(json)

        XCTAssertEqual(feed.partnerName, "Sam")
        XCTAssertEqual(feed.connection?.name, "Flatmates")
        XCTAssertTrue(feed.isGroup)
        XCTAssertEqual(feed.beerCount, 2)
        XCTAssertEqual(feed.looCount, 1)
        XCTAssertEqual(feed.post?.id, "x")
        XCTAssertEqual(feed.moments?.count, 1)
        XCTAssertEqual(feed.unreadCount, 1)
    }
}
