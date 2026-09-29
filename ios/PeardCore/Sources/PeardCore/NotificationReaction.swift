import Foundation

/// A reaction fired from a notification's quick actions (issue #263).
///
/// Kept apart from the app so the same request is made whether or not the app
/// has a model: iOS answers a notification action on an app that was killed by
/// launching it into the background, with no window and so no model, and a
/// reaction that only went through the model was dropped there.
///
/// Sending one twice is harmless — the unique index on post, user and kind
/// refuses the second — so a retry needs no bookkeeping.
public struct NotificationReaction: Equatable, Sendable {
    public let postID: String
    public let kind: ReactionKind

    public static let actionPrefix = "REACT_"

    public static func actionIdentifier(for kind: ReactionKind) -> String {
        actionPrefix + kind.rawValue
    }

    /// The reaction an action identifier stands for, or `nil` for any other
    /// action or a notification that names no post.
    public init?(actionIdentifier: String, postID: String?) {
        guard
            actionIdentifier.hasPrefix(Self.actionPrefix),
            let postID, !postID.isEmpty
        else { return nil }
        let raw = String(actionIdentifier.dropFirst(Self.actionPrefix.count))
        guard !raw.isEmpty else { return nil }
        self.postID = postID
        self.kind = ReactionKind(rawValue: raw)
    }

    /// The body of the `reactions` record this creates for `userID`.
    public func fields(userID: String) -> [String: String] {
        ["post": postID, "user": userID, "kind": kind.rawValue]
    }
}
