import Foundation

/// What a new-moment or reaction notification says about the post it is for.
///
/// The server puts the post, its connection and — for a moment — its kind in
/// every such alert (`notifyPairMembers` and `notifyPostAuthor` in
/// `server/internal/push`). The weekly recap names a connection but no post,
/// so it does not parse: it is a summary to read, not a moment that will show
/// up on a screen, and none of what follows applies to it.
///
/// Parsed from `userInfo` straight away, where the notification is received,
/// because that dictionary is not `Sendable` and this is.
public struct MomentPush: Hashable, Sendable {
    public let postID: String
    public let pairID: String
    /// `nil` for a photo on its own and for a reaction, neither of which is a
    /// moment somebody could log back.
    public let eventKind: EventKind?

    public init(postID: String, pairID: String, eventKind: EventKind? = nil) {
        self.postID = postID
        self.pairID = pairID
        self.eventKind = eventKind
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard
            let postID = userInfo["post_id"] as? String, !postID.isEmpty,
            let pairID = userInfo["pair_id"] as? String, !pairID.isEmpty
        else { return nil }
        self.postID = postID
        self.pairID = pairID
        let kind = (userInfo["event_kind"] as? String).map(EventKind.init(rawValue:))
        self.eventKind = kind?.isEmpty == false ? kind : nil
    }

    /// Whether the connection this is about is the one on screen, in which
    /// case the screen can show the moment itself and a banner over it only
    /// repeats what is about to appear underneath.
    public func isFor(connectionOnScreen pairID: String?) -> Bool {
        guard let pairID, !pairID.isEmpty else { return false }
        return pairID == self.pairID
    }
}
