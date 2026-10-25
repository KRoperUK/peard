import XCTest

@testable import PeardCore

/// The durable queue for reactions tapped from a notification (#366). The two
/// ways to get it wrong mirror the send queue's: lose a reaction a Lock-Screen
/// tap made offline, or send one twice (the server dedupes, but the queue should
/// not keep retrying one it already delivered).
final class ReactionQueueTests: XCTestCase {
    private final class MemoryStore: PendingReactionStore, @unchecked Sendable {
        private let lock = NSLock()
        private var reactions: [PendingReaction]

        init(_ initial: [PendingReaction] = []) { reactions = initial }

        func loadPendingReactions() -> [PendingReaction] {
            lock.lock(); defer { lock.unlock() }
            return reactions
        }

        func savePendingReactions(_ newValue: [PendingReaction]) {
            lock.lock(); defer { lock.unlock() }
            reactions = newValue
        }

        var stored: [PendingReaction] {
            lock.lock(); defer { lock.unlock() }
            return reactions
        }
    }

    private func reaction(
        post: String = "p1",
        user: String = "me",
        kind: ReactionKind = .heart,
        tappedAt: Date = Date()
    ) -> PendingReaction {
        PendingReaction(postID: post, userID: user, kind: kind, tappedAt: tappedAt)
    }

    /// What the drain sent, visible across the actor boundary without a data
    /// race: the `send` closure is `@Sendable`, so it cannot close over a
    /// mutable local.
    private final class SentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fields: [[String: String]] = []

        func record(_ next: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            fields.append(next)
        }

        var all: [[String: String]] {
            lock.lock(); defer { lock.unlock() }
            return fields
        }
    }

    // MARK: Enqueue

    func testEnqueuePersistsImmediately() async {
        let store = MemoryStore()
        let queue = ReactionQueue(store: store)

        await queue.enqueue(reaction())

        XCTAssertEqual(store.stored.count, 1, "a tap must be on disk before the send is tried")
    }

    // The same reaction tapped twice before it sends is one row, not two —
    // matching the server's unique (post, user, kind).
    func testEnqueueDedupesTheSameReaction() async {
        let store = MemoryStore()
        let queue = ReactionQueue(store: store)

        await queue.enqueue(reaction(post: "p1", kind: .heart))
        await queue.enqueue(reaction(post: "p1", kind: .heart))

        XCTAssertEqual(store.stored.count, 1)
    }

    func testDifferentKindsOnOnePostAreSeparate() async {
        let store = MemoryStore()
        let queue = ReactionQueue(store: store)

        await queue.enqueue(reaction(post: "p1", kind: .heart))
        await queue.enqueue(reaction(post: "p1", kind: .cheers))

        XCTAssertEqual(store.stored.count, 2)
    }

    // MARK: Drain

    func testDrainDeliversAndClears() async {
        let store = MemoryStore([reaction(post: "p1"), reaction(post: "p2")])
        let queue = ReactionQueue(store: store)

        let sent = SentBox()
        let delivered = await queue.drain { sent.record($0) }

        XCTAssertEqual(delivered, 2)
        XCTAssertTrue(store.stored.isEmpty, "a delivered reaction is removed, not retried forever")
        XCTAssertEqual(Set(sent.all.map { $0["post"] }), ["p1", "p2"])
    }

    // A retryable failure (no signal) keeps the reaction for the next launch.
    func testDrainKeepsAReactionThatFailsRetryably() async {
        let store = MemoryStore([reaction(post: "p1")])
        let queue = ReactionQueue(store: store)

        let delivered = await queue.drain { _ in
            throw APIError.transport("not connected")
        }

        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(store.stored.count, 1, "a retryable failure must not drop the reaction")
    }

    // A permanent failure (the post is gone, the user left) is dropped, not
    // retried forever.
    func testDrainDropsAReactionThatFailsPermanently() async {
        let store = MemoryStore([reaction(post: "p1")])
        let queue = ReactionQueue(store: store)

        let delivered = await queue.drain { _ in
            throw APIError.server(status: 404, message: "gone")
        }

        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(store.stored.isEmpty, "a permanent failure drops the reaction rather than burning launches on it")
    }

    // A reaction that has sat unsent longer than a day is no longer worth
    // surfacing as if freshly made.
    func testDrainDropsReactionsTooOldToSend() async {
        let old = reaction(post: "p1", tappedAt: Date().addingTimeInterval(-48 * 60 * 60))
        let store = MemoryStore([old])
        let queue = ReactionQueue(store: store)

        let sent = SentBox()
        let delivered = await queue.drain { sent.record($0) }

        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(sent.all.count, 0, "a day-old reaction is not sent")
        XCTAssertTrue(store.stored.isEmpty, "and it is dropped, not kept")
    }

    func testRemoveTakesOneOut() async {
        let r = reaction(post: "p1")
        let store = MemoryStore([r])
        let queue = ReactionQueue(store: store)

        await queue.remove(id: r.id)

        XCTAssertTrue(store.stored.isEmpty)
    }
}
