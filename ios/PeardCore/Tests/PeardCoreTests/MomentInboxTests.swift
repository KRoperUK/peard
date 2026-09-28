import XCTest
@testable import PeardCore

/// The hand-off from an extension that could not reach the server to the app
/// that will. Like the send queue, the two ways to get it wrong are losing a
/// moment and sending one twice.
final class MomentInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: MomentInbox!
    private var queue: SendQueue!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-inbox-\(UUID().uuidString)")
        inbox = MomentInbox(url: directory.appendingPathComponent("extension-inbox.json"))
        queue = SendQueue(store: FilePendingSendStore(url: directory.appendingPathComponent("pending-sends.json")))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        inbox = nil
        queue = nil
        directory = nil
        super.tearDown()
    }

    private func moment(id: String = UUID().uuidString, pair: String? = "p1") -> InboxedMoment {
        InboxedMoment(
            id: id, pairID: pair, kind: .beer, emoji: "🍺", label: "Beer",
            queuedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    // MARK: The extension's side

    func testAppendedMomentsSurviveOnDisk() {
        inbox.append(moment(id: "a"))
        inbox.append(moment(id: "b"))

        // A fresh instance, as the app would have: nothing held in memory.
        let reread = MomentInbox(url: inbox.url).load()
        XCTAssertEqual(reread.map(\.id), ["a", "b"])
    }

    /// An intent the system re-runs must not inbox the same tap twice.
    func testAppendingTheSameIDTwiceKeepsOne() {
        inbox.append(moment(id: "a"))
        inbox.append(moment(id: "a"))

        XCTAssertEqual(inbox.load().count, 1)
    }

    // MARK: The app's side

    func testMergeMovesMomentsIntoTheQueueAndEmptiesTheInbox() async {
        inbox.append(moment(id: "a"))

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 1)
        XCTAssertTrue(inbox.load().isEmpty)
        let queued = await queue.pending
        XCTAssertEqual(queued.map(\.id), ["a"])
        XCTAssertEqual(queued.first?.authorID, "me")
        XCTAssertEqual(queued.first?.pairID, "p1")
        XCTAssertEqual(queued.first?.queuedAt, Date(timeIntervalSince1970: 1_790_000_000))
        // The extension's client id goes out again, so a first attempt that did
        // land cannot be logged a second time.
        XCTAssertEqual(queued.first?.postFields["client_id"], "a")
    }

    /// A crash after queueing but before the inbox was emptied leaves the
    /// moment in both. The next merge must not queue it again.
    func testMergingTwiceDoesNotDuplicate() async {
        let leftover = moment(id: "a")
        inbox.append(leftover)
        await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)
        inbox.append(leftover)

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 0)
        let count = await queue.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(inbox.load().isEmpty)
    }

    /// Control Centre and Siri name no connection; the app supplies one.
    func testAMomentWithNoConnectionTakesTheFallback() async {
        inbox.append(moment(id: "a", pair: nil))

        await queue.absorb(inbox, authorID: "me", fallbackPairID: "p2")

        let queued = await queue.pending
        XCTAssertEqual(queued.first?.pairID, "p2")
    }

    /// With nowhere to put it yet, it waits rather than being dropped.
    func testAMomentWithNowhereToGoStaysInTheInbox() async {
        inbox.append(moment(id: "a", pair: nil))
        inbox.append(moment(id: "b"))

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 1)
        XCTAssertEqual(inbox.load().map(\.id), ["a"])
    }

    /// No session means no author, so nothing can be queued yet.
    func testNothingIsTakenWithoutAnAuthor() async {
        inbox.append(moment(id: "a"))

        let added = await queue.absorb(inbox, authorID: "", fallbackPairID: nil)

        XCTAssertEqual(added, 0)
        XCTAssertEqual(inbox.load().count, 1)
    }

    /// Removal names what it read, so something the extension appended in the
    /// meantime is not swept away with it.
    func testRemovingKeepsEntriesAppendedSinceTheyWereRead() {
        inbox.append(moment(id: "a"))
        let read = Set(inbox.load().map(\.id))
        inbox.append(moment(id: "b"))

        inbox.remove(ids: read)

        XCTAssertEqual(inbox.load().map(\.id), ["b"])
    }
}
