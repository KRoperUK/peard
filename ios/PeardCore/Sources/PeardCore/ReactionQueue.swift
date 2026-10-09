import Foundation

/// One reaction tapped from a notification that has not reached the server yet
/// (#366).
///
/// A reaction fired from the Lock Screen runs in a background launch with only
/// seconds of runtime and often no network — the old path tried once and
/// dropped it. This is the record that lets it survive: it is written before the
/// send is attempted and removed once the send succeeds, so a reaction tapped
/// with no signal is still there to retry on the next launch.
///
/// Idempotent on the server (the unique index on post, user and kind refuses a
/// second), so a retry needs no bookkeeping beyond "have we sent this yet".
public struct PendingReaction: Codable, Equatable, Sendable, Identifiable {
    public let postID: String
    public let userID: String
    public let kind: ReactionKind
    /// When it was tapped, so the drain can order oldest-first and drop one that
    /// has sat unsent for longer than a reaction is worth sending.
    public let tappedAt: Date

    /// Stable per (post, user, kind): the same tap re-persisted replaces its own
    /// row rather than piling up, matching the server's own uniqueness.
    public var id: String { "\(postID)|\(userID)|\(kind.rawValue)" }

    public init(postID: String, userID: String, kind: ReactionKind, tappedAt: Date = Date()) {
        self.postID = postID
        self.userID = userID
        self.kind = kind
        self.tappedAt = tappedAt
    }

    /// The `reactions` record body this creates, identical to
    /// `NotificationReaction.fields` so the two paths write the same thing.
    public var fields: [String: String] {
        ["post": postID, "user": userID, "kind": kind.rawValue]
    }
}

/// Where pending notification reactions live between launches.
///
/// A protocol for the same reason `PendingSendStore` is one: the App Group
/// container backs it in the app, a temporary directory in tests.
public protocol PendingReactionStore: Sendable {
    func loadPendingReactions() -> [PendingReaction]
    func savePendingReactions(_ reactions: [PendingReaction])
}

/// A `PendingReactionStore` backed by a JSON file in the App Group container, so
/// a reaction tapped from the Lock Screen (which the notification-service and the
/// app may both touch) survives to the next launch (#366).
///
/// Mirrors `FilePendingSendStore`: an atomic write, a corrupt file moved aside
/// rather than overwritten, and an empty save removing the file.
public struct FilePendingReactionStore: PendingReactionStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func appGroup(
        identifier: String = SharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> FilePendingReactionStore {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FilePendingReactionStore(url: directory.appendingPathComponent("pending-reactions.json"))
    }

    public func loadPendingReactions() -> [PendingReaction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let reactions = try? JSONDecoder.peard.decode([PendingReaction].self, from: data) {
            return reactions
        }
        // Unreadable: move it aside rather than let the next save overwrite it,
        // the same guard FilePendingSendStore makes (#342).
        let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    public func savePendingReactions(_ reactions: [PendingReaction]) {
        if reactions.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.peard.encode(reactions) else {
            assertionFailure("PendingReactionStore: failed to encode \(reactions.count) reaction(s)")
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// The durable queue of notification reactions: persist on tap, drain on launch.
///
/// An actor so the Lock-Screen path (a background launch) and the app's own
/// drain cannot race the file. Deduped by `PendingReaction.id`, so tapping the
/// same reaction twice before it sends keeps one row, not two.
public actor ReactionQueue {
    private let store: PendingReactionStore
    /// A reaction older than this is dropped unsent on drain: a day-old tap is
    /// no longer worth surfacing to the other person as if it were just made.
    private let maxAge: TimeInterval

    public init(store: PendingReactionStore, maxAge: TimeInterval = 24 * 60 * 60) {
        self.store = store
        self.maxAge = maxAge
    }

    /// Records a reaction so it survives this launch ending before it sends.
    public func enqueue(_ reaction: PendingReaction) {
        var pending = store.loadPendingReactions()
        pending.removeAll { $0.id == reaction.id }
        pending.append(reaction)
        store.savePendingReactions(pending)
    }

    /// Removes one, once it has reached the server.
    public func remove(id: String) {
        var pending = store.loadPendingReactions()
        pending.removeAll { $0.id == id }
        store.savePendingReactions(pending)
    }

    public func pending() -> [PendingReaction] {
        store.loadPendingReactions().sorted { $0.tappedAt < $1.tappedAt }
    }

    /// Sends every pending reaction, dropping the ones too old to be worth it and
    /// the ones the server refuses as permanent. `send` throws to signal a
    /// retryable failure; a reaction that fails that way is left for next time.
    ///
    /// Returns the number that reached the server, so a caller can decide whether
    /// anything changed worth a refresh.
    @discardableResult
    public func drain(
        now: Date = Date(),
        send: (_ fields: [String: String]) async throws -> Void
    ) async -> Int {
        var pending = store.loadPendingReactions().sorted { $0.tappedAt < $1.tappedAt }
        var delivered = 0
        var survivors: [PendingReaction] = []
        for reaction in pending {
            if now.timeIntervalSince(reaction.tappedAt) > maxAge {
                continue // too old; drop silently
            }
            do {
                try await send(reaction.fields)
                delivered += 1
            } catch {
                if case .permanent = SendFailure.classify(error) {
                    continue // the post is gone or the user left; stop trying
                }
                survivors.append(reaction) // retryable: keep for next launch
            }
        }
        _ = pending
        store.savePendingReactions(survivors)
        return delivered
    }
}
