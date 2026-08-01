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
    /// Its own flag rather than a kind, because a photo has no `event_kind` at
    /// all — it is a different sort of post, not a different moment.
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
    /// A kind and "photos only" are mutually exclusive — a photo has no kind, so
    /// asking for both would always match nothing. Photos win, because that is
    /// the one the person just chose in the only UI that can set both.
    public var clauses: [String] {
        var clauses: [String] = []
        if let author, !author.isEmpty {
            clauses.append(PeardFilter.equals("author", author))
        }
        if photosOnly {
            clauses.append(PeardFilter.equals("type", PostType.photo.rawValue))
        } else if let kind, !kind.rawValue.isEmpty {
            clauses.append(PeardFilter.equals("event_kind", kind.rawValue))
        }
        return clauses
    }

    /// Cleared of the dimension a caller is about to set, so choosing a kind
    /// turns off "photos only" and vice versa rather than leaving a filter that
    /// matches nothing.
    public func choosing(kind: EventKind?) -> TimelineFilter {
        TimelineFilter(author: author, kind: kind, photosOnly: false)
    }

    public func choosingPhotos(_ photos: Bool) -> TimelineFilter {
        TimelineFilter(author: author, kind: photos ? nil : kind, photosOnly: photos)
    }

    public func choosing(author: String?) -> TimelineFilter {
        TimelineFilter(author: author, kind: kind, photosOnly: photosOnly)
    }
}
