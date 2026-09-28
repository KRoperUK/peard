import Foundation

/// "Me too" or a typed reply, answered straight from a moment's notification
/// (issue #154).
///
/// Both become a post in the same connection and go the way every moment does:
/// through the send queue, so they survive a bad network. The moment is built
/// as an `InboxedMoment` rather than a `PendingSend` because the app may not be
/// running to fill in the author — iOS answers a notification action by
/// launching it into the background, where there is no screen and so no model
/// — and the inbox is how a moment waits for the app. When the app is running
/// it becomes a `PendingSend` straight away.
///
/// A reply is a post of its own that is only words (`PostType.note`), not a
/// note attached to a reaction. A reaction has nowhere to keep words — no
/// field, and one row per person and kind, so a second reply with the same
/// reaction would be refused — and it does not go through the send queue at
/// all. A post already has `note`, which every client draws and every alert
/// carries as its body, and the queue already knows how to deliver one.
public enum NotificationAnswer: Equatable, Sendable {
    /// Log the same moment back to the same connection.
    case meToo
    /// Send these words to the same connection.
    case reply(String)

    public static let meTooIdentifier = "ME_TOO"
    public static let replyIdentifier = "REPLY"

    /// The answer an action identifier stands for, or `nil` for any other
    /// action — a reaction, or a tap on the notification itself.
    public init?(actionIdentifier: String, text: String?) {
        switch actionIdentifier {
        case Self.meTooIdentifier: self = .meToo
        case Self.replyIdentifier: self = .reply(text ?? "")
        default: return nil
        }
    }

    /// The moment this answer logs, or `nil` when there is nothing to send:
    /// "me too" to something that was not a moment (a photo, a reply), or a
    /// reply with no words in it.
    ///
    /// "Me too" is drawn from the built-in catalogue, falling back to the
    /// pear and the slug read as a label for a connection's own kind — the
    /// app has no catalogue to hand in the background. That only shows while
    /// the moment is still queued; once it lands it is drawn like any other.
    public func moment(for push: MomentPush, id: String = UUID().uuidString, at date: Date = Date()) -> InboxedMoment? {
        switch self {
        case .meToo:
            guard let kind = push.eventKind else { return nil }
            return InboxedMoment(
                id: id,
                pairID: push.pairID,
                kind: kind,
                emoji: MomentCatalogue.emoji(for: kind),
                label: MomentCatalogue.label(for: kind),
                queuedAt: date
            )
        case .reply(let text):
            let note = PostNote.normalised(text)
            guard !note.isEmpty else { return nil }
            return InboxedMoment(
                id: id,
                pairID: push.pairID,
                kind: EventKind(rawValue: ""),
                emoji: MomentCatalogue.replyEmoji,
                label: MomentCatalogue.replyLabel,
                queuedAt: date,
                note: note,
                postType: .note
            )
        }
    }
}
