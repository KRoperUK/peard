import XCTest
@testable import PeardCore

/// Answering a photo with words or a photo of your own (issue #304): what is
/// read back, and what the queue sends.
final class PhotoReplyTests: XCTestCase {
    private let decoder = JSONDecoder.peard
    private let photo = Post(
        id: "photo1", pair: "pair1", author: "ada", type: .photo,
        media: "p.jpg", created: Date(timeIntervalSince1970: 1_790_000_000)
    )

    // MARK: Reading posts

    func testAReplyNamesThePhotoItAnswers() throws {
        let post = try decoder.decode(Post.self, from: Data("""
        {"id":"r1","pair":"x","author":"a","type":"note","note":"lovely",
         "created":"2026-09-27 12:00:00.000Z","reply_to":"photo1"}
        """.utf8))

        XCTAssertEqual(post.replyTo, "photo1")
    }

    /// PocketBase sends an unset relation as an empty string.
    func testAnUnsetReplyToIsNoReply() throws {
        let post = try decoder.decode(Post.self, from: Data("""
        {"id":"p1","pair":"x","author":"a","type":"photo",
         "created":"2026-09-27 12:00:00.000Z","reply_to":""}
        """.utf8))

        XCTAssertNil(post.replyTo)
    }

    func testAPostFromAnOlderServerAnswersNothing() throws {
        let post = try decoder.decode(Post.self, from: Data("""
        {"id":"p1","pair":"x","author":"a","type":"photo","created":"2026-09-27 12:00:00.000Z"}
        """.utf8))

        XCTAssertNil(post.replyTo)
    }

    // MARK: Sending

    func testWordsGoAsANoteOnThePhoto() throws {
        let send = try XCTUnwrap(PendingSend.reply(to: photo, authorID: "bo", note: "  lovely  ", withPhoto: false))
        let fields = send.postFields

        XCTAssertEqual(fields["type"], "note")
        XCTAssertEqual(fields["note"], "lovely")
        XCTAssertEqual(fields["reply_to"], "photo1")
        XCTAssertEqual(fields["pair"], "pair1")
        XCTAssertNil(fields["event_kind"], "an answer is never a moment")
        XCTAssertFalse(send.hasPhoto)
    }

    func testAPhotoSentBackIsAPhotoOnThePhoto() throws {
        let send = try XCTUnwrap(PendingSend.reply(to: photo, authorID: "bo", note: "", withPhoto: true))

        XCTAssertEqual(send.postFields["type"], "photo")
        XCTAssertEqual(send.postFields["reply_to"], "photo1")
        XCTAssertTrue(send.hasPhoto)
    }

    func testEmptyWordsAreNothingToSend() {
        XCTAssertNil(PendingSend.reply(to: photo, authorID: "bo", note: "   ", withPhoto: false))
    }

    func testAnOrdinarySendAnswersNothing() {
        let send = PendingSend(pairID: "p", authorID: "a", kind: .beer, emoji: "🍺", label: "Beer")

        XCTAssertNil(send.postFields["reply_to"])
    }

    /// A reply waiting for signal is still a reply, after the app is killed and
    /// relaunched.
    func testAQueuedReplyKeepsWhatItAnswers() throws {
        let send = try XCTUnwrap(PendingSend.reply(to: photo, authorID: "bo", note: "lovely", withPhoto: false))

        let decoded = try JSONDecoder().decode(PendingSend.self, from: JSONEncoder().encode(send))

        XCTAssertEqual(decoded.replyTo, "photo1")
        XCTAssertEqual(decoded.optimisticPost.replyTo, "photo1")
    }

    /// A queue written before replies existed has no `reply_to` and must still
    /// load.
    func testAQueueFromBeforeRepliesStillLoads() throws {
        let decoded = try JSONDecoder().decode(PendingSend.self, from: Data("""
        {"id":"s1","pair":"p","author":"a","kind":"beer","emoji":"🍺","label":"Beer",
         "queued_at":0}
        """.utf8))

        XCTAssertNil(decoded.replyTo)
    }
}
