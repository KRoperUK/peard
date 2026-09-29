import XCTest
@testable import PeardCore

/// "Me too" and "Reply" on a moment's notification, as the posts they send.
final class NotificationAnswerTests: XCTestCase {
    private let beer = MomentPush(postID: "post1", pairID: "pair1", eventKind: .beer)
    private let photo = MomentPush(postID: "post2", pairID: "pair1")

    private func send(_ answer: NotificationAnswer, to push: MomentPush) -> PendingSend? {
        answer.moment(for: push, id: "answer1")?.pendingSend(authorID: "me", fallbackPairID: "elsewhere")
    }

    // MARK: Actions

    func testOnlyMeTooAndReplyAreAnswers() {
        XCTAssertEqual(NotificationAnswer(actionIdentifier: "ME_TOO", text: nil), .meToo)
        XCTAssertEqual(NotificationAnswer(actionIdentifier: "REPLY", text: "enjoy!"), .reply("enjoy!"))
        XCTAssertNil(NotificationAnswer(actionIdentifier: "REACT_cheers", text: nil))
        XCTAssertNil(NotificationAnswer(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", text: nil))
    }

    // MARK: Me too

    func testMeTooLogsTheSameMomentToTheSameConnection() throws {
        let send = try XCTUnwrap(send(.meToo, to: beer))

        XCTAssertEqual(send.id, "answer1")
        XCTAssertEqual(send.pairID, "pair1", "the connection the alert came from, not the fallback")
        XCTAssertEqual(send.authorID, "me")
        XCTAssertEqual(send.kind, .beer)
        XCTAssertEqual(send.emoji, "🍺")
        XCTAssertEqual(send.label, "Beer")
        XCTAssertEqual(send.postType, .event)
        XCTAssertEqual(send.note, "")
        let fields = send.postFields
        XCTAssertEqual(fields["type"], "event")
        XCTAssertEqual(fields["event_kind"], "beer")
        XCTAssertEqual(fields["client_id"], "answer1")
    }

    func testMeTooToACustomMomentReadsItsSlug() throws {
        let tea = MomentPush(postID: "post1", pairID: "pair1", eventKind: "flat_white")

        let send = try XCTUnwrap(send(.meToo, to: tea))

        XCTAssertEqual(send.kind, "flat_white")
        XCTAssertEqual(send.emoji, MomentCatalogue.fallbackEmoji)
        XCTAssertEqual(send.label, "Flat white")
    }

    func testMeTooToSomethingThatWasNotAMomentSendsNothing() {
        XCTAssertNil(send(.meToo, to: photo))
    }

    // MARK: Reply

    func testAReplyIsAPostOfWordsInTheSameConnection() throws {
        let send = try XCTUnwrap(send(.reply("  enjoy!\n"), to: photo))

        XCTAssertEqual(send.pairID, "pair1")
        XCTAssertEqual(send.postType, .note)
        XCTAssertEqual(send.note, "enjoy!")
        XCTAssertEqual(send.emoji, "💬")
        let fields = send.postFields
        XCTAssertEqual(fields["type"], "note")
        XCTAssertEqual(fields["note"], "enjoy!")
        XCTAssertNil(fields["event_kind"], "a reply is not a moment, and must not count as one")
    }

    func testAReplyIsCappedAtTheServersLimit() throws {
        let send = try XCTUnwrap(send(.reply(String(repeating: "a", count: 400)), to: beer))

        XCTAssertEqual(send.note.count, PostNote.limit)
    }

    func testAnEmptyReplySendsNothing() {
        XCTAssertNil(send(.reply(""), to: beer))
        XCTAssertNil(send(.reply("   \n"), to: beer))
    }

    func testARepliedToMomentDoesNotCountInTheTallies() throws {
        let reply = try XCTUnwrap(send(.reply("enjoy!"), to: beer))

        let tallies = ConnectionTallies(pair: "pair1", mine: .zero, others: .zero, kinds: [])

        let merged = tallies.adding(pending: [reply])

        XCTAssertEqual(merged.mine, .zero)
        XCTAssertTrue(merged.kinds.isEmpty)
    }

    // MARK: Through the inbox

    /// With the app not running, the answer waits in the inbox; the words and
    /// the type have to come out the other side.
    func testAReplyKeepsItsWordsThroughTheInbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = MomentInbox(url: directory.appendingPathComponent("extension-inbox.json"))
        let queue = SendQueue(store: FilePendingSendStore(url: directory.appendingPathComponent("pending-sends.json")))
        let moment = try XCTUnwrap(NotificationAnswer.reply("enjoy!").moment(for: beer))

        XCTAssertTrue(inbox.append(moment))
        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 1)
        let pending = await queue.pending
        let send = try XCTUnwrap(pending.first)
        XCTAssertEqual(send.id, moment.id)
        XCTAssertEqual(send.postType, .note)
        XCTAssertEqual(send.note, "enjoy!")
    }

    /// An inbox written by a build from before replies still loads, as events.
    func testAnOlderInboxEntryIsAnEvent() throws {
        let json = #"[{"id":"a","pair":"p","kind":"beer","emoji":"🍺","label":"Beer","queued_at":"2026-09-01 10:00:00.000Z"}]"#

        let moments = try JSONDecoder.peard.decode([InboxedMoment].self, from: Data(json.utf8))

        let send = try XCTUnwrap(moments.first?.pendingSend(authorID: "me", fallbackPairID: nil))
        XCTAssertEqual(send.postType, .event)
        XCTAssertEqual(send.note, "")
    }
}
