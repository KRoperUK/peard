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

    /// Sends this reaction, retrying a bounded number of times on a retryable
    /// failure before giving up (#341).
    ///
    /// The old path made exactly one `try?` attempt from a background launch and
    /// dropped the reaction on any failure — a flaky network between the tap and
    /// the server lost it silently. Reactions are idempotent (the unique index on
    /// post, user and kind refuses a second), so retrying is safe with no
    /// bookkeeping; a permanent failure (the post is gone, the user left the
    /// connection) stops at once rather than burning the window.
    ///
    /// `send` is injected so the sender's one line of `APIClient.create` stays in
    /// the app and this stays unit-testable. `sleep` is injected for the same
    /// reason the backoff is short: a background launch has only seconds, so the
    /// delays are small and a test can make them zero.
    ///
    /// - Returns: true if the reaction reached the server (or was already there),
    ///   false if every attempt failed with a retryable error inside the budget.
    @discardableResult
    public func send(
        userID: String,
        attempts: Int = 3,
        send: (_ fields: [String: String]) async throws -> Void,
        sleep: (_ seconds: Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async -> Bool {
        guard !userID.isEmpty else { return false }
        let body = fields(userID: userID)
        for attempt in 0..<max(1, attempts) {
            do {
                try await send(body)
                return true
            } catch {
                if case .permanent = SendFailure.classify(error) {
                    // The post is gone or the user has left; retrying cannot help.
                    return false
                }
                // Retryable: a short backoff, unless this was the last attempt.
                if attempt < attempts - 1 {
                    await sleep(Double(attempt + 1) * 0.5)
                }
            }
        }
        return false
    }
}
