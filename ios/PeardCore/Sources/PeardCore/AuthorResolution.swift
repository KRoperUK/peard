import Foundation

/// Who wrote a moment, as the home screen and the timeline both name and draw
/// them.
///
/// Both screens used to carry their own copy of this, and the copies had already
/// drifted: for an author who is no longer a member of a 1:1, the home screen
/// named the *current* partner while the timeline said "Someone". The timeline
/// was right. In a 1:1 the only way to have posts from somebody who is not a
/// member is for them to have left, so the current partner — if there is one —
/// is by definition a different person, and naming them credits them with
/// somebody else's evening. The home screen's own avatar already drew that
/// author's initials as "Someone", so it disagreed with itself as well as with
/// the timeline. `othersLabel` settled on the same neutral name for the same
/// reason.
///
/// Static and taking an optional connection because both models reach for this
/// on the first frame of a cold launch, before the connection list has loaded,
/// and the answer then still has to be drawable.
public extension Connection {
    /// What the signed-in user's own moments are attributed to.
    static let youLabel = "You"

    /// Names the author of a moment. In a group this is the individual, not
    /// "Others", so a shared timeline reads as a conversation.
    static func authorLabel(
        for userID: String,
        in connection: Connection?,
        signedInUserID: String
    ) -> String {
        if userID == signedInUserID { return youLabel }
        // Not a current member: they have left, but their moments stay in the
        // shared timeline. See the type comment for why this is never the
        // current partner's name.
        return connection?.name(forUser: userID) ?? PartnerLabel.unknown
    }

    /// The author's photo, or their initials.
    ///
    /// A former member is not in the list any more, so there is nothing to draw
    /// but initials — of the same neutral name `authorLabel` gives them, rather
    /// than a path to a file that would 404.
    static func authorAvatar(for userID: String, in connection: Connection?) -> Avatar {
        if let member = connection?.members.first(where: { $0.user == userID }) {
            return member.avatar
        }
        return Avatar(
            owner: .users,
            recordID: userID,
            filename: nil,
            placeholder: .make(name: PartnerLabel.unknown, key: userID)
        )
    }
}
