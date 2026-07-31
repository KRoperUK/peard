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
}
