import Foundation

/// The text a post carries: a note on a moment, a caption on a photo.
///
/// One field, two names — the app calls it a note when it explains a moment and
/// a caption when it describes a picture, but the server stores both in `note`
/// and validates both the same way. The rules were written out three times
/// (the edit sheet, the photo sheet, the upload) with the limit as a bare `280`
/// in each, which is exactly the sort of thing that drifts from the server and
/// only announces itself as a 400 in somebody's hand.
public enum PostNote {
    /// Matches the `note` field's `Max` in the posts collection, and the
    /// server's `maxNoteLength`. Changing it means changing all three.
    public static let limit = 280

    /// What a text field should hold while somebody is still typing.
    ///
    /// Length only — deliberately no trimming, because trimming mid-sentence
    /// would swallow the space that was just typed and make the field feel
    /// broken. Being stopped at the limit is better than being told afterwards
    /// that the words are gone.
    public static func capped(_ raw: String) -> String {
        raw.count > limit ? String(raw.prefix(limit)) : raw
    }

    /// What actually gets sent: trimmed, then capped.
    ///
    /// Empty means "no note" rather than "an empty note", so whitespace alone
    /// is the same as saying nothing — which is what somebody who typed a
    /// space and thought better of it meant.
    public static func normalised(_ raw: String) -> String {
        capped(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a draft is worth sending, for callers that only need to decide
    /// whether to show or send something.
    public static func isEmpty(_ raw: String) -> Bool {
        normalised(raw).isEmpty
    }
}
