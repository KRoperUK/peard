import Foundation

/// What the timeline is narrowed to: one person, one kind of moment, or only
/// the photos.
///
/// A shared timeline is append-only and unbounded — a group of twelve tapping
/// moments accumulates thousands of rows — so "when did we last do that" and
/// "what has she been up to" become unanswerable by scrolling long before the
/// history stops being interesting.
///
/// The dimensions combine: one person's coffees is a reasonable question. They
/// are separate fields rather than one enum for exactly that reason.
public struct TimelineFilter: Hashable, Sendable {
    /// A member's user id, or nil for everybody.
    public var author: String?
    /// A moment kind, or nil for all of them.
    public var kind: EventKind?
    /// Only posts carrying a photo.
    ///
    /// Its own flag rather than a kind, because a photo is not a kind of
    /// moment — it is something a post can have. A moment can now carry one
    /// too, so this asks "has an image attached" rather than "is a photo
    /// post", and it combines with a kind: "the coffees I photographed" is a
    /// question somebody can now ask.
    public var photosOnly: Bool

    public static let none = TimelineFilter()

    public init(author: String? = nil, kind: EventKind? = nil, photosOnly: Bool = false) {
        self.author = author
        self.kind = kind
        self.photosOnly = photosOnly
    }

    public var isActive: Bool {
        author != nil || kind != nil || photosOnly
    }

    /// PocketBase filter clauses, to be joined with the caller's own.
    ///
    /// The two used to be mutually exclusive, and the reason was sound while it
    /// lasted: a photo post had no `event_kind`, so asking for both matched
    /// nothing. Now that a moment can carry a photo they compose, and the
    /// photo clause tests the attachment rather than the post type — a coffee
    /// with a picture of it is a photo by every meaning except the old one.
    public var clauses: [String] {
        var clauses: [String] = []
        if let author, !author.isEmpty {
            clauses.append(PeardFilter.equals("author", author))
        }
        if photosOnly {
            clauses.append("media != \"\"")
        }
        if let kind, !kind.rawValue.isEmpty {
            clauses.append(PeardFilter.equals("event_kind", kind.rawValue))
        }
        return clauses
    }

    /// Each dimension is set on its own now. They used to clear each other,
    /// because together they matched nothing; a moment that carries a photo
    /// makes the combination meaningful instead.
    public func choosing(kind: EventKind?) -> TimelineFilter {
        TimelineFilter(author: author, kind: kind, photosOnly: photosOnly)
    }

    public func choosingPhotos(_ photos: Bool) -> TimelineFilter {
        TimelineFilter(author: author, kind: kind, photosOnly: photos)
    }

    public func choosing(author: String?) -> TimelineFilter {
        TimelineFilter(author: author, kind: kind, photosOnly: photosOnly)
    }
}
