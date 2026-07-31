import XCTest
@testable import Peard
import PeardCore

/// Which moments the timeline marks as new.
///
/// The rule has three ways to be wrong, and all three are silent: marking your
/// own moments new, marking everything new when there is no watermark, and
/// getting the boundary comparison inclusive when it should be exclusive. None
/// would fail a build or show an error — the line would just sit in the wrong
/// place, or everywhere.
@MainActor
final class NewMomentsDividerTests: XCTestCase {
    private let serverURL = URL(string: "http://127.0.0.1:8090")!
    private let watermark = Date(timeIntervalSince1970: 1_700_000_000)

    private func model(watermark: Date?) -> HistoryModel {
        HistoryModel(
            api: APIClient(baseURL: serverURL),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil,
            unreadWatermark: watermark
        )
    }

    private func post(id: String = "p1", author: String, offset: TimeInterval) -> Post {
        Post(
            id: id,
            pair: "pair1",
            author: author,
            type: .event,
            eventKind: .beer,
            created: watermark.addingTimeInterval(offset)
        )
    }

    func testSomebodyElsesMomentAfterTheWatermarkIsNew() {
        let subject = model(watermark: watermark)

        XCTAssertTrue(subject.isNew(post(author: "ari", offset: 60)))
    }

    func testAMomentBeforeTheWatermarkIsNotNew() {
        let subject = model(watermark: watermark)

        XCTAssertFalse(subject.isNew(post(author: "ari", offset: -60)))
    }

    /// You were there when you logged it. Counting your own would put the line
    /// above a moment you just posted, which reads as the app telling you about
    /// yourself.
    func testYourOwnMomentIsNeverNew() {
        let subject = model(watermark: watermark)

        XCTAssertFalse(subject.isNew(post(author: "me", offset: 60)))
    }

    /// Nothing was waiting when the connection was opened, so nothing is marked.
    /// Without this guard a nil watermark would compare against zero and light
    /// up the entire history.
    func testNoWatermarkMarksNothing() {
        let subject = model(watermark: nil)

        XCTAssertFalse(subject.isNew(post(author: "ari", offset: 60)))
        XCTAssertFalse(subject.isNew(post(author: "ari", offset: -60)))
        XCTAssertNil(subject.firstNewPostID)
    }

    /// The watermark is the last moment you saw, not the first you did not — a
    /// post created exactly at it has already been seen.
    func testAMomentExactlyAtTheWatermarkIsNotNew() {
        let subject = model(watermark: watermark)

        XCTAssertFalse(subject.isNew(post(author: "ari", offset: 0)))
    }

    /// A server predating read state sends no stamp, so the connection decodes
    /// with none and the timeline draws no line — rather than treating the
    /// absence as "everything is new".
    func testAConnectionWithoutAStampYieldsNoWatermark() throws {
        let json = #"{"pair":"p1","unread":3}"#
        let connection = try JSONDecoder.peard.decode(Connection.self, from: Data(json.utf8))

        XCTAssertNil(connection.lastSeenAt)
        XCTAssertEqual(connection.unreadCount, 3, "the count still decodes")
        XCTAssertFalse(model(watermark: connection.lastSeenAt).isNew(post(author: "ari", offset: 60)))
    }
}
