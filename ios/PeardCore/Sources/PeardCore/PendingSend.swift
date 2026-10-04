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
    /// `.photo` for a photo with no moment attached; `.event` otherwise,
    /// including a moment that carries a photo. Only events count in tallies.
    public let postType: PostType
    /// A JPEG waits in `PendingPhotoStore` under this send's id, and goes up
    /// with it as a multipart upload.
    public let hasPhoto: Bool
    /// When the moment happened, if somebody rewound it. `nil` means it
    /// happened when it was tapped, and the server stamps it on arrival.
    public let happenedAt: Date?
    /// The photo this send answers, when it is a comment on one or a photo sent
    /// back; see `reply(to:authorID:note:withPhoto:)`.
    public let replyTo: String?
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
        case postType = "post_type"
        case hasPhoto = "has_photo"
        case happenedAt = "happened_at"
        case replyTo = "reply_to"
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
        postType: PostType = .event,
        hasPhoto: Bool = false,
        happenedAt: Date? = nil,
        replyTo: String? = nil,
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
        self.postType = postType
        self.hasPhoto = hasPhoto
        self.happenedAt = happenedAt
        self.replyTo = replyTo
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    /// Written by hand so a queue saved by an older build still loads: it has
    /// no `post_type` or `has_photo`, and the synthesized decoder would reject
    /// the whole file — losing every moment in it, which is the one thing the
    /// queue exists to prevent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pairID = try c.decode(String.self, forKey: .pairID)
        authorID = try c.decode(String.self, forKey: .authorID)
        kind = try c.decode(EventKind.self, forKey: .kind)
        emoji = try c.decode(String.self, forKey: .emoji)
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        queuedAt = try c.decode(Date.self, forKey: .queuedAt)
        postType = try c.decodeIfPresent(PostType.self, forKey: .postType) ?? .event
        hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
        happenedAt = try c.decodeIfPresent(Date.self, forKey: .happenedAt)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    /// Fields for the `posts` record this send becomes.
    public var postFields: [String: String] { postFields(now: Date()) }

    /// Fields for the record, as sent at `now`.
    ///
    /// A picked time goes as a rewind. A moment that simply waited in the queue
    /// goes with the time it was tapped, so a beer logged in a basement lands
    /// when it was drunk rather than when the signal came back — and without the
    /// chip, because nobody filled it in after the fact. One that has waited
    /// longer than the server accepts a time for is sent without one and lands
    /// on arrival, as it always did, rather than being refused and lost.
    public func postFields(now: Date) -> [String: String] {
        var fields = [
            "pair": pairID,
            "author": authorID,
            "type": postType.rawValue,
            "note": note,
            // Written to the record so a retry after a lost response can find
            // the row it already created instead of making a second one.
            "client_id": id,
        ]
        if postType == .event { fields["event_kind"] = kind.rawValue }
        if let replyTo { fields["reply_to"] = replyTo }
        if let happenedAt {
            fields["happened_at"] = Rewind.wireString(happenedAt)
            fields["rewound"] = "true"
        } else {
            let waited = now.timeIntervalSince(queuedAt)
            if waited > Rewind.threshold, waited < Rewind.lateSendWindow {
                fields["happened_at"] = Rewind.wireString(queuedAt)
            }
        }
        return fields
    }

    /// When the moment happened, for drawing and counting it before the server
    /// has.
    public var happenedOrQueuedAt: Date { happenedAt ?? queuedAt }

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
            type: postType,
            eventKind: postType == .event ? kind : nil,
            note: note.isEmpty ? nil : note,
            created: queuedAt,
            happenedAt: happenedOrQueuedAt,
            rewound: happenedAt.map { Rewind.isRewound($0, loggedAt: queuedAt) } ?? false,
            replyTo: replyTo
        )
    }

    /// An answer to a photo (issue #304): words typed under it, or — with a
    /// photo — a picture sent back, captioned with the words if there are any.
    ///
    /// The same kind of send as a reply typed into a notification or a photo
    /// shared on its own, with `reply_to` added, so it queues, survives a bad
    /// network and is drawn while waiting exactly as those are. Never a moment:
    /// answering a photo is not doing anything, and the server refuses a moment
    /// that claims to.
    ///
    /// `nil` for words alone with nothing in them.
    public static func reply(
        to photo: Post,
        authorID: String,
        note: String,
        withPhoto: Bool,
        id: String = UUID().uuidString,
        at date: Date = Date()
    ) -> PendingSend? {
        let note = PostNote.normalised(note)
        guard withPhoto || !note.isEmpty else { return nil }
        return PendingSend(
            id: id,
            pairID: photo.pair,
            authorID: authorID,
            kind: EventKind(rawValue: ""),
            emoji: withPhoto ? "📸" : MomentCatalogue.replyEmoji,
            label: withPhoto ? "Photo" : MomentCatalogue.replyLabel,
            note: note,
            queuedAt: date,
            postType: withPhoto ? .photo : .note,
            hasPhoto: withPhoto,
            replyTo: photo.id
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
