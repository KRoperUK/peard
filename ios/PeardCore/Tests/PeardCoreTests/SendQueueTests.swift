import XCTest
@testable import PeardCore

/// The offline queue. These are the tests that matter most in the whole suite:
/// the queue holds moments somebody logged, and the two ways to get it wrong are
/// losing one and sending one twice.
final class SendQueueTests: XCTestCase {
    /// An in-memory store, so the tests exercise the queue rather than the disk.
    private final class MemoryStore: PendingSendStore, @unchecked Sendable {
        private let lock = NSLock()
        private var sends: [PendingSend]
        /// How many times the queue asked for a write, to prove it persists before
        /// a request is attempted.
        private(set) var writes = 0

        init(_ initial: [PendingSend] = []) {
            sends = initial
        }

        func loadPendingSends() -> [PendingSend] {
            lock.lock(); defer { lock.unlock() }
            return sends
        }

        func savePendingSends(_ newValue: [PendingSend]) {
            lock.lock(); defer { lock.unlock() }
            sends = newValue
            writes += 1
        }

        var stored: [PendingSend] {
            lock.lock(); defer { lock.unlock() }
            return sends
        }
    }

    private func send(
        _ kind: EventKind = .beer,
        id: String = UUID().uuidString,
        pair: String = "p1",
        queuedAt: Date = Date(),
        attempts: Int = 0,
        lastAttemptAt: Date? = nil
    ) -> PendingSend {
        PendingSend(
            id: id, pairID: pair, authorID: "me", kind: kind,
            emoji: "🍺", label: "Beer", queuedAt: queuedAt,
            attempts: attempts, lastAttemptAt: lastAttemptAt
        )
    }

    // MARK: Enqueue

    /// The moment has to be on disk before the request is tried, or killing the
    /// app mid-flight loses it.
    func testEnqueuePersistsImmediately() async {
        let store = MemoryStore()
        let queue = SendQueue(store: store)

        await queue.enqueue(send())

        XCTAssertEqual(store.stored.count, 1)
        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    func testQueueIsRestoredFromTheStoreOnInit() async {
        let store = MemoryStore([send(id: "a"), send(id: "b", pair: "p2")])
        let queue = SendQueue(store: store)

        let count = await queue.count
        let inP2 = await queue.pending(forPair: "p2").map(\.id)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(inP2, ["b"])
    }

    // MARK: Flush

    func testSuccessfulFlushClearsTheQueue() async {
        let store = MemoryStore()
        let queue = SendQueue(store: store)
        await queue.enqueue(send(id: "a"))
        await queue.enqueue(send(id: "b"))

        let result = await queue.flush { _ in }

        XCTAssertEqual(result.sent, 2)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertTrue(store.stored.isEmpty)
    }

    func testSendsAreAttemptedOldestFirst() async {
        let queue = SendQueue(store: MemoryStore())
        // Within SendQueue.maxAge, or the flush's prune would discard both before
        // either could be attempted.
        let now = Date()
        await queue.enqueue(send(id: "old", queuedAt: now.addingTimeInterval(-120)))
        await queue.enqueue(send(id: "new", queuedAt: now.addingTimeInterval(-60)))

        let order = Order()
        _ = await queue.flush(now: now) { await order.record($0.id) }

        let ids = await order.ids
        XCTAssertEqual(ids, ["old", "new"])
    }

    /// A retryable failure almost always means there is no connectivity, so the
    /// rest of the queue would fail too — and would burn its retry budget doing
    /// it. The flush stops at the first one.
    func testFlushStopsAtTheFirstRetryableFailure() async {
        let queue = SendQueue(store: MemoryStore())
        await queue.enqueue(send(id: "a"))
        await queue.enqueue(send(id: "b"))
        await queue.enqueue(send(id: "c"))

        let order = Order()
        let result = await queue.flush { pending in
            await order.record(pending.id)
            throw APIError.transport("offline")
        }

        let attemptedIDs = await order.ids
        XCTAssertEqual(attemptedIDs, ["a"])
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(result.remaining, 3)    }

    /// A 400 is the `client_id` unique index rejecting a send that already landed:
    /// the moment is recorded, so the queue entry must go rather than retry
    /// forever.
    func testDuplicateIsDroppedRatherThanRetried() async {
        let queue = SendQueue(store: MemoryStore())
        await queue.enqueue(send(id: "dup"))

        let result = await queue.flush { _ in
            throw APIError.server(status: 400, message: "client_id must be unique")
        }

        XCTAssertEqual(result.abandoned, 1)
        XCTAssertEqual(result.remaining, 0)
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }

    /// A permanent failure on one send must not stop the ones behind it.
    func testFlushContinuesPastAPermanentFailure() async {
        let queue = SendQueue(store: MemoryStore())
        await queue.enqueue(send(id: "bad"))
        await queue.enqueue(send(id: "good"))

        let result = await queue.flush { pending in
            if pending.id == "bad" { throw APIError.server(status: 403, message: "not a member") }
        }

        XCTAssertEqual(result.abandoned, 1)
        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.remaining, 0)
    }

    /// A 401 might just be a token that expired while the device was offline.
    /// Discarding somebody's moments over that would be the worst outcome.
    func testUnauthorizedIsRetryableRatherThanDiscarded() async {
        let queue = SendQueue(store: MemoryStore())
        await queue.enqueue(send(id: "a"))

        let result = await queue.flush { _ in throw APIError.unauthorized(message: nil) }

        XCTAssertEqual(result.failed, 1)
        let stillQueued = await queue.count
        XCTAssertEqual(stillQueued, 1)
    }

    /// A send inside its backoff window is skipped, not retried.
    func testSendWaitingOutItsBackoffIsSkipped() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // attempts=3 gives an 8 second delay; the last attempt was 1 second ago.
        let waiting = send(id: "waiting", attempts: 3, lastAttemptAt: now.addingTimeInterval(-1))
        let queue = SendQueue(store: MemoryStore([waiting]))

        let attempted = Order()
        let result = await queue.flush(now: now) { await attempted.record($0.id) }

        let attemptedIDs = await attempted.ids
        XCTAssertEqual(attemptedIDs, [])
        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(result.remaining, 1)
    }

    func testSendPastItsBackoffIsRetried() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let ready = send(id: "ready", attempts: 3, lastAttemptAt: now.addingTimeInterval(-60))
        let queue = SendQueue(store: MemoryStore([ready]))

        let result = await queue.flush(now: now) { _ in }

        XCTAssertEqual(result.sent, 1)
    }

    /// Concurrent flushes must not double-post. Two callers is the real case: a
    /// reachability change and a foreground refresh landing together.
    func testConcurrentFlushesDoNotDoublePost() async {
        let queue = SendQueue(store: MemoryStore())
        await queue.enqueue(send(id: "a"))
        let counter = Counter()

        async let first = queue.flush { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await counter.increment()
        }
        async let second = queue.flush { _ in await counter.increment() }
        _ = await (first, second)

        let performed = await counter.value
        XCTAssertEqual(performed, 1)
    }

    // MARK: Ageing and abandonment

    func testSendsOlderThanTheMaximumAgeArePruned() async {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let stale = send(id: "stale", queuedAt: now.addingTimeInterval(-SendQueue.maxAge - 1))
        let fresh = send(id: "fresh", queuedAt: now.addingTimeInterval(-60))
        let queue = SendQueue(store: MemoryStore([stale, fresh]))

        let removed = await queue.prune(now: now)

        XCTAssertEqual(removed, 1)
        let survivors = await queue.pending.map(\.id)
        XCTAssertEqual(survivors, ["fresh"])
    }

    func testSendStopsBeingRetriedAfterTheAttemptLimit() async {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let exhausted = send(id: "done", attempts: PendingSend.maxAttempts, lastAttemptAt: now.addingTimeInterval(-10_000))
        let queue = SendQueue(store: MemoryStore([exhausted]))

        let attempted = Order()
        _ = await queue.flush(now: now) { await attempted.record($0.id) }

        let attemptedIDs = await attempted.ids
        let stalled = await queue.stalled.count
        XCTAssertEqual(attemptedIDs, [])
        XCTAssertEqual(stalled, 1)
    }

    func testRevivingStalledSendsMakesThemReadyAgain() async {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let exhausted = send(id: "done", attempts: PendingSend.maxAttempts, lastAttemptAt: now)
        let queue = SendQueue(store: MemoryStore([exhausted]))

        await queue.reviveStalled()
        let result = await queue.flush(now: now) { _ in }

        XCTAssertEqual(result.sent, 1)
        let stalled = await queue.stalled
        XCTAssertTrue(stalled.isEmpty)
    }

    // MARK: Persistence across operations

    /// Every operation that changes the queue has to reach the store, because the
    /// store is what survives a launch.
    func testStoreTracksEveryChange() async {
        let store = MemoryStore([send(id: "a")])
        let queue = SendQueue(store: store)

        await queue.enqueue(send(id: "b"))
        XCTAssertEqual(store.stored.map(\.id), ["a", "b"])

        await queue.remove(id: "a")
        XCTAssertEqual(store.stored.map(\.id), ["b"])

        _ = await queue.flush { _ in }
        XCTAssertTrue(store.stored.isEmpty)
    }

    // MARK: File store

    func testFileStoreRoundTripsAndRemovesTheFileWhenEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-queue-test-\(UUID().uuidString).json")
        let store = FilePendingSendStore(url: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let original = send(id: "a", queuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.savePendingSends([original])

        let loaded = store.loadPendingSends()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "a")
        XCTAssertEqual(loaded[0].kind, .beer)
        XCTAssertEqual(loaded[0].queuedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        store.savePendingSends([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.loadPendingSends().isEmpty)
    }

    /// A truncated or hand-edited file must read as "nothing queued" rather than
    /// crashing the app on launch.
    func testFileStoreTreatsCorruptContentAsEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-queue-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)

        XCTAssertTrue(FilePendingSendStore(url: url).loadPendingSends().isEmpty)
    }

    // MARK: Optimistic post

    /// A pending row and the real record it becomes must never collide in a
    /// `ForEach`, or SwiftUI will complain and draw one of them wrong.
    func testOptimisticPostIDIsNamespaced() {
        let pending = send(id: "abc")
        XCTAssertEqual(pending.optimisticPost.id, "pending:abc")
        XCTAssertEqual(pending.optimisticPost.eventKind, .beer)
        XCTAssertEqual(pending.optimisticPost.author, "me")
    }

    func testPostFieldsCarryTheClientIDForIdempotency() {
        let fields = send(id: "abc").postFields
        XCTAssertEqual(fields["client_id"], "abc")
        XCTAssertEqual(fields["type"], "event")
        XCTAssertEqual(fields["event_kind"], "beer")
    }

    // MARK: Backoff

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(send(attempts: 0).retryDelay, 0)
        XCTAssertEqual(send(attempts: 1).retryDelay, 2)
        XCTAssertEqual(send(attempts: 2).retryDelay, 4)
        XCTAssertEqual(send(attempts: 5).retryDelay, 32)
        XCTAssertEqual(send(attempts: 8).retryDelay, 256)
        // Capped at five minutes however many attempts have been made.
        XCTAssertEqual(send(attempts: 50).retryDelay, 256)
    }
}

// MARK: - Test helpers

/// Records the order in which sends were attempted.
private actor Order {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
