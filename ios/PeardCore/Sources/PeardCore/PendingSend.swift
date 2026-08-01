import Foundation

/// A moment that has been logged on the device but not yet accepted by the
/// server.
///
/// The premise of the app is that a moment costs one tap, and the moments people
/// actually want are beer in a pub basement and loo on a train — precisely where
/// there is no signal. Before this existed, `commitQuickSend` showed "Couldn't log
/// it" and threw the moment away.
///
/// A pending send is written to disk before the request is attempted, so it also
/// survives the app being killed mid-request.
public struct PendingSend: Codable, Hashable, Sendable, Identifiable {
    /// Stable across retries and across launches, and reused as the idempotency
    /// key so a send that succeeded but whose response was lost cannot be
    /// duplicated on the next flush.
    public let id: String
    public let pairID: String
    public let authorID: String
    public let kind: EventKind
    /// Kept alongside the slug so the pending row can be drawn — and can move the
    /// tally — without consulting the connection's catalogue, which may itself be
    /// unreachable.
    public let emoji: String
    public let label: String
    public let note: String
    public let queuedAt: Date
    /// How many times a flush has tried and failed. Drives the retry backoff.
    public var attempts: Int
    /// When the last attempt failed, for the backoff calculation.
    public var lastAttemptAt: Date?
    /// The last failure, shown after the queue gives up.
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, emoji, label, note, attempts
        case pairID = "pair"
        case authorID = "author"
        case queuedAt = "queued_at"
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
    }

    public init(
        id: String = UUID().uuidString,
        pairID: String,
        authorID: String,
        kind: EventKind,
        emoji: String,
        label: String,
        note: String = "",
        queuedAt: Date = Date(),
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.pairID = pairID
        self.authorID = authorID
        self.kind = kind
        self.emoji = emoji
        self.label = label
        self.note = note
        self.queuedAt = queuedAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    /// Fields for the `posts` record this send becomes.
    public var postFields: [String: String] {
        [
            "pair": pairID,
            "author": authorID,
            "type": PostType.event.rawValue,
            "event_kind": kind.rawValue,
            "note": note,
            // Written to the record so a retry after a lost response can find
            // the row it already created instead of making a second one.
            "client_id": id,
        ]
    }

    /// Beyond this many failed attempts the send stops being retried
    /// automatically and is surfaced for the user to retry or discard. Chosen so
    /// a genuinely unreachable server does not spin forever, while an ordinary
    /// tunnel or lift outage is ridden out.
    public static let maxAttempts = 8

    public var hasGivenUp: Bool { attempts >= Self.maxAttempts }

    /// Exponential backoff, doubling from 2 seconds and capped at 5 minutes, so a
    /// server that is down is not hammered.
    public var retryDelay: TimeInterval {
        guard attempts > 0 else { return 0 }
        let exponential = pow(2.0, Double(min(attempts, 8))) // 2 … 256
        return min(exponential, 300)
    }

    /// True when enough time has passed since the last failure to try again.
    public func isReady(now: Date = Date()) -> Bool {
        guard !hasGivenUp else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryDelay
    }

    /// A copy marked as having just failed.
    public func failed(with message: String, at date: Date = Date()) -> PendingSend {
        var copy = self
        copy.attempts += 1
        copy.lastAttemptAt = date
        copy.lastError = message
        return copy
    }

    /// A copy with the failure history cleared, for an explicit user retry.
    public var revived: PendingSend {
        var copy = self
        copy.attempts = 0
        copy.lastAttemptAt = nil
        copy.lastError = nil
        return copy
    }

    /// The optimistic post shown in the timeline while the send is queued.
    ///
    /// `id` is the client id, which no server record uses, so a pending row and
    /// the real one it becomes never collide in a `ForEach`.
    public var optimisticPost: Post {
        Post(
            id: "pending:" + id,
            pair: pairID,
            author: authorID,
            type: .event,
            eventKind: kind,
            note: note.isEmpty ? nil : note,
            created: queuedAt
        )
    }
}

/// Whether a failure is worth retrying.
public enum SendFailure: Sendable {
    /// No network, a timeout, a 5xx: the send is still good, try later.
    case retryable(String)
    /// The server rejected the request itself (a 400, or a 403 because the user
    /// has left the connection). Retrying cannot help.
    case permanent(String)

    /// Classifies an error from `APIClient`.
    ///
    /// A 401 is deliberately *retryable*: the token may simply have expired while
    /// the device was offline, and discarding somebody's moments because of that
    /// would be the worst possible outcome. The caller handles the session side
    /// separately.
    public static func classify(_ error: Error) -> SendFailure {
        guard let apiError = error as? APIError else {
            return .retryable(error.localizedDescription)
        }
        switch apiError {
        case .invalidURL:
            // A misconfigured server URL will not fix itself by waiting.
            return .permanent("The server URL is not valid.")
        case .transport(let message):
            return .retryable(message)
        case .cancelled:
            // Nothing was learned: the request went away before the server
            // answered, so the moment may or may not have been written. Retrying
            // is the safe half of that — `client_id` makes the write idempotent,
            // so a duplicate cannot result, whereas giving up loses a moment
            // somebody logged.
            return .retryable("Interrupted")
        case .unauthorized:
            return .retryable("Not signed in")
        case .decoding(let message):
            // The record was probably created; the response just could not be
            // read. Treating it as permanent avoids a duplicate.
            return .permanent(message)
        case .server(let status, let message):
            let text = message ?? "Server error \(status)"
            if status == 400 || status == 403 || status == 404 { return .permanent(text) }
            return .retryable(text)
        }
    }
}
