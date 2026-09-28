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
    /// Text to find in a note or caption, or in a moment's name (issue #9).
    /// Trimmed; empty means no search.
    public var search: String
    /// The kinds whose *label* contains `search` — "flat white" finds the
    /// `flat_white` moment even though no note says so. Worked out by the
    /// caller from its catalogue, because the server knows slugs, not labels.
    public var searchKinds: [String]

    public static let none = TimelineFilter()

    public init(
        author: String? = nil,
        kind: EventKind? = nil,
        photosOnly: Bool = false,
        search: String = "",
        searchKinds: [String] = []
    ) {
        self.author = author
        self.kind = kind
        self.photosOnly = photosOnly
        self.search = search
        self.searchKinds = searchKinds
    }

    public var isActive: Bool {
        author != nil || kind != nil || photosOnly || !search.isEmpty
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
        if !search.isEmpty {
            // One group, ANDed with the rest: it composes with who and which
            // kind rather than replacing them. `~` is PocketBase's
            // case-insensitive "contains", run on the server, so it reaches
            // every page and not only what is loaded.
            let text = PeardFilter.escaped(search)
            clauses.append(PeardFilter.or(
                ["note ~ \"\(text)\"", "event_kind ~ \"\(text)\""]
                    + searchKinds.map { PeardFilter.equals("event_kind", $0) }
            ))
        }
        return clauses
    }

    /// Searching for `text`, keeping everything else. `catalogue` is what the
    /// connection calls its moments, so a search can match a name as well as a
    /// note.
    public func searching(_ text: String, catalogue: [Moment]) -> TimelineFilter {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kinds = trimmed.isEmpty ? [] : catalogue
            .filter { $0.label.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.kind.rawValue)
        var copy = self
        copy.search = trimmed
        copy.searchKinds = kinds
        return copy
    }

    /// Each dimension is set on its own now. They used to clear each other,
    /// because together they matched nothing; a moment that carries a photo
    /// makes the combination meaningful instead.
    public func choosing(kind: EventKind?) -> TimelineFilter {
        var copy = self
        copy.kind = kind
        return copy
    }

    public func choosingPhotos(_ photos: Bool) -> TimelineFilter {
        var copy = self
        copy.photosOnly = photos
        return copy
    }

    public func choosing(author: String?) -> TimelineFilter {
        var copy = self
        copy.author = author
        return copy
    }
}
