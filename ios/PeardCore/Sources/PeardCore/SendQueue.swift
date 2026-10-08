import Foundation

/// Where a `SendQueue` keeps its pending sends between launches.
///
/// A protocol so the queue can be tested without touching the filesystem, and so
/// the App Group container can back it in the app while a plain temporary
/// directory backs it in tests.
public protocol PendingSendStore: Sendable {
    func loadPendingSends() -> [PendingSend]
    func savePendingSends(_ sends: [PendingSend])
}

/// A `PendingSendStore` backed by a JSON file.
///
/// The queue lives in a file rather than `UserDefaults` because it is the record
/// of moments somebody logged: a synchronous, atomic write with a failure this
/// code can see beats a preference domain that flushes when it feels like it.
public struct FilePendingSendStore: PendingSendStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The queue file inside the App Group container, so a share extension or the
    /// widget could contribute to it later. Falls back to Application Support
    /// when the container is unavailable (which is the case in unit tests and on
    /// a misconfigured provisioning profile).
    public static func appGroup(
        identifier: String = SharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> FilePendingSendStore {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FilePendingSendStore(url: directory.appendingPathComponent("pending-sends.json"))
    }

    public func loadPendingSends() -> [PendingSend] {
        guard let data = try? Data(contentsOf: url) else {
            // No file is the ordinary empty case: first launch, or the queue was
            // drained and the file removed. Nothing to preserve.
            return []
        }
        if let sends = try? JSONDecoder.peard.decode([PendingSend].self, from: data) {
            return sends
        }
        // The file exists but will not decode — truncated by a crash mid-write, or
        // hand-edited. The app still launches with an empty queue (it must not
        // crash on a bad file), but the bytes are moved ASIDE first: otherwise the
        // next savePendingSends would overwrite the only copy of moments somebody
        // logged, turning a recoverable corruption into silent data loss (#342).
        quarantineCorruptFile()
        return []
    }

    /// Moves the unreadable queue file next to itself as `*.corrupt`, so the
    /// moments it held can be recovered rather than overwritten on the next save.
    /// Best-effort: a previous quarantine is replaced, and a failure here leaves
    /// the original in place (still better than deleting it).
    private func quarantineCorruptFile() {
        let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            // Could not move it; leave the original untouched rather than risk
            // destroying it. The next save still will not clobber it, because the
            // original is only removed on an empty save, which the queue does not
            // issue while it believes it holds nothing from a failed decode.
        }
    }

    public func savePendingSends(_ sends: [PendingSend]) {
        if sends.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.peard.encode(sends) else {
            // The queue could not be encoded. The old code silently dropped the
            // write here; that is the "failure this code can see" the type's doc
            // promises to act on, so leave whatever is already on disk in place
            // rather than pretending the save happened (#342).
            assertionFailure("SendQueue: failed to encode \(sends.count) pending send(s)")
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `.atomic` so a crash mid-write cannot leave a truncated queue, which
        // would lose every moment in it rather than one.
        try? data.write(to: url, options: .atomic)
    }
}

/// The outcome of flushing the queue once.
public struct FlushResult: Hashable, Sendable {
    public var sent: Int
    public var failed: Int
    public var abandoned: Int
    /// Still queued after the flush, including those waiting out a backoff.
    public var remaining: Int

    public init(sent: Int = 0, failed: Int = 0, abandoned: Int = 0, remaining: Int = 0) {
        self.sent = sent
        self.failed = failed
        self.abandoned = abandoned
        self.remaining = remaining
    }

    public var didChangeAnything: Bool { sent > 0 || abandoned > 0 }
}

/// A durable queue of moments waiting to reach the server.
///
/// An `actor` because it is touched from the UI (enqueueing a tap), from a
/// reachability callback, and from a background refresh — all concurrently. The
/// invariant worth protecting is that one send is never posted twice, and the
/// only way to hold that without locks is to serialise access.
///
/// Sends are attempted oldest first and the flush stops at the first retryable
/// failure, so a connection that has just come back does not fire twelve doomed
/// requests, and moments keep their order.
public actor SendQueue {
    /// A pending send is dropped after this long even if it never succeeded.
    /// A moment is about *now*; one from four days ago is noise, and keeping it
    /// forever would mean a permanently broken server slowly filling the disk.
    public static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    private let store: PendingSendStore
    private var sends: [PendingSend]
    /// Set while a flush is running so a second caller does not double-post.
    private var isFlushing = false

    public init(store: PendingSendStore) {
        self.store = store
        self.sends = store.loadPendingSends()
    }

    public var pending: [PendingSend] { sends }

    public func pending(forPair pairID: String) -> [PendingSend] {
        sends.filter { $0.pairID == pairID }
    }

    public var count: Int { sends.count }

    /// Sends that have exhausted their retries and need a decision.
    public var stalled: [PendingSend] { sends.filter(\.hasGivenUp) }

    /// Adds a send and persists it before any request is attempted, which is what
    /// makes the moment survive the app being killed mid-flight.
    @discardableResult
    public func enqueue(_ send: PendingSend) async -> PendingSend {
        sends.append(send)
        persist()
        return send
    }

    /// Clears one send, used when the caller has established it is already
    /// recorded server-side.
    public func remove(id: String) async {
        sends.removeAll { $0.id == id }
        persist()
    }

    /// Replaces one queued send with `transform` of itself, keeping its place in
    /// the queue, and persists. A no-op when `id` is not queued — it may have
    /// been sent, or discarded, between the caller reading it and asking.
    ///
    /// For editing what a send says before it goes (#313). The transform must
    /// return a send with the same `id`: that is what the photo file, the
    /// timeline row and the server's idempotency key are all keyed on.
    public func update(id: String, _ transform: (PendingSend) -> PendingSend) async {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return }
        sends[index] = transform(sends[index])
        persist()
    }

    /// Resets the failure history of every abandoned send so the next flush tries
    /// again. Driven by an explicit "try again" in the UI.
    public func reviveStalled() async {
        sends = sends.map { $0.hasGivenUp ? $0.revived : $0 }
        persist()
    }

    public func removeAll() async {
        sends.removeAll()
        persist()
    }

    /// Drops sends older than `maxAge`, returning how many went.
    @discardableResult
    public func prune(now: Date = Date()) async -> Int {
        let before = sends.count
        sends.removeAll { now.timeIntervalSince($0.queuedAt) > Self.maxAge }
        let removed = before - sends.count
        if removed > 0 { persist() }
        return removed
    }

    /// Attempts every ready send, oldest first.
    ///
    /// `perform` does the actual POST. It is injected rather than called on an
    /// `APIClient` held here so this type stays testable and so the caller keeps
    /// control of session handling: a 401 is retryable here, but the app still
    /// needs to notice it.
    @discardableResult
    public func flush(
        now: Date = Date(),
        perform: @Sendable (PendingSend) async throws -> Void
    ) async -> FlushResult {
        guard !isFlushing else {
            return FlushResult(remaining: sends.count)
        }
        isFlushing = true
        defer { isFlushing = false }

        await prune(now: now)

        var result = FlushResult()
        var index = 0

        while index < sends.count {
            let send = sends[index]
            guard send.isReady(now: now) else {
                index += 1
                continue
            }

            // The queue can be changed while `perform` is suspended — a send
            // edited or deleted from the UI — so the send is found again by id
            // afterwards. Removing by the index taken before the await would
            // take out a different send (or trap) once something ahead of it
            // had gone.
            do {
                try await perform(send)
                index = drop(send.id, near: index)
                result.sent += 1
                continue
            } catch {
                switch SendFailure.classify(error) {
                case .permanent:
                    // Already recorded (the client_id index rejected a duplicate)
                    // or refused outright. Either way, retrying cannot help.
                    index = drop(send.id, near: index)
                    result.abandoned += 1
                    continue
                case .retryable(let message):
                    // A cancelled flush was never a real attempt: nothing was
                    // learned about the server, so counting it would spend the
                    // send's retry budget — and start its backoff — on a request
                    // that was withdrawn rather than refused (issue #58). The
                    // send is left exactly as it was for the next flush.
                    if Task.isCancelled || error is CancellationError
                        || (error as? APIError)?.isCancellation == true {
                        result.remaining = sends.count
                        if result.didChangeAnything { persist() }
                        return result
                    }
                    // Applied to the queue's current copy, which an edit made
                    // while this request was out has already replaced.
                    if let current = sends.firstIndex(where: { $0.id == send.id }) {
                        sends[current] = sends[current].failed(with: message, at: now)
                    }
                    result.failed += 1
                    // Stop at the first retryable failure: it almost certainly
                    // means no connectivity, so the rest would fail too, and
                    // pressing on would burn their retry budgets for nothing.
                    result.remaining = sends.count
                    persist()
                    return result
                }
            }
        }

        result.remaining = sends.count
        if result.didChangeAnything || result.failed > 0 { persist() }
        return result
    }

    /// Removes the send with `id` and returns where the flush should carry on
    /// from: the slot it occupied, or `fallback` when it has already gone.
    private func drop(_ id: String, near fallback: Int) -> Int {
        let slot = sends.firstIndex { $0.id == id }
        sends.removeAll { $0.id == id }
        return slot ?? min(fallback, sends.count)
    }

    private func persist() {
        store.savePendingSends(sends)
    }
}
