import Foundation

/// Where an avatar's bytes live, and what to draw when there are none.
///
/// The server sends the *stored filename* rather than a URL, matching how
/// `posts.media` already travels: a URL would bake the host into a response the
/// device caches, and the device already knows its own base URL. Turning that
/// filename into a path needs the owning collection and record id, which is what
/// this type carries.
public struct Avatar: Hashable, Sendable {
    /// The PocketBase collection holding the file field.
    public enum Owner: String, Hashable, Sendable {
        case users
        case pairs
    }

    /// A requested thumbnail size. Only sizes the migration declared exist;
    /// asking for anything else makes PocketBase serve the original, which for a
    /// rail of twelve circles is several megabytes of nothing.
    public enum Thumb: String, Hashable, Sendable {
        /// 128×128 — the connection rail and member rows.
        case small = "128x128"
        /// 512×512 — the settings screen's large circle.
        case large = "512x512"
    }

    public let owner: Owner
    public let recordID: String
    /// The stored filename, or nil when nothing has been uploaded.
    public let filename: String?
    /// What to draw in place of a photo: initials over a stable colour.
    public let placeholder: AvatarPlaceholder

    public init(owner: Owner, recordID: String, filename: String?, placeholder: AvatarPlaceholder) {
        self.owner = owner
        self.recordID = recordID
        self.filename = filename?.isEmpty == true ? nil : filename
        self.placeholder = placeholder
    }

    /// True when there is a photo to fetch.
    public var hasImage: Bool { filename != nil }

    /// The path under the server's base URL, or nil when there is no photo.
    ///
    /// Percent-encoded because a stored filename is derived from whatever the
    /// device uploaded, and an unescaped space produces a URL that silently fails
    /// to build.
    public func path(thumb: Thumb? = .small) -> String? {
        guard let filename else { return nil }
        let escaped = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let base = "/api/files/\(owner.rawValue)/\(recordID)/\(escaped)"
        guard let thumb else { return base }
        return base + "?thumb=" + thumb.rawValue
    }

    /// The absolute URL to fetch, or nil when there is no photo.
    public func url(base: URL, thumb: Thumb? = .small) -> URL? {
        guard let path = path(thumb: thumb) else { return nil }
        return URL(string: base.absoluteString.trimmingTrailingSlash + path)
    }
}

/// What to draw when somebody has no photo.
///
/// Initials plus a colour derived from a stable key, so the same person is the
/// same colour on every screen and after every relaunch — which is most of what
/// makes an avatar rail scannable at 40 points.
public struct AvatarPlaceholder: Hashable, Sendable {
    /// One or two letters taken from the name.
    public let initials: String
    /// Index into `AvatarPalette.colours`, derived from the key.
    public let colourIndex: Int
    /// True when the subject is a group, so the UI can draw a group glyph
    /// instead of initials for an unnamed one.
    public let isGroup: Bool

    public init(initials: String, colourIndex: Int, isGroup: Bool = false) {
        self.initials = initials
        self.colourIndex = colourIndex
        self.isGroup = isGroup
    }

    /// Derives initials and a colour from a name and a stable key.
    ///
    /// The key is the record id rather than the name: renaming a group should not
    /// change its colour, and two people called "Sam" should not be the same
    /// colour just because they share a name.
    public static func make(name: String, key: String, isGroup: Bool = false) -> AvatarPlaceholder {
        AvatarPlaceholder(
            initials: AvatarInitials.derive(from: name),
            colourIndex: AvatarPalette.index(for: key),
            isGroup: isGroup
        )
    }
}

/// Initials for an avatar.
public enum AvatarInitials {
    /// First letters of the first two words, uppercased.
    ///
    /// Grapheme-clustered rather than character-sliced, so a name beginning with
    /// an emoji or a combining mark yields that whole symbol instead of half of
    /// one. Falls back to a pear when there is nothing usable, which is the same
    /// answer the rest of the app gives for "unknown".
    public static func derive(from name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber || $0.isSymbol }) }

        let letters = words.prefix(2).compactMap { word -> String? in
            guard let first = word.first else { return nil }
            return String(first).uppercased()
        }
        guard !letters.isEmpty else { return "🍐" }
        return letters.joined()
    }
}

/// The colours an avatar placeholder may take.
public enum AvatarPalette {
    /// Eight hues that hold up against the Pear'd background in both
    /// appearances. Deliberately not the accent colour: the accent means
    /// "actionable", and an avatar is not a button.
    public static let colours: [UInt32] = [
        0x4C7A3F, // moss
        0x2F6F7A, // teal
        0x7A5230, // bark
        0x8A4B6B, // plum
        0x3F5C8A, // slate blue
        0x8A7530, // ochre
        0x5C3F8A, // iris
        0x8A3F3F, // brick
    ]

    /// A stable index for a key.
    ///
    /// FNV-1a rather than `hashValue`: Swift's string hashing is seeded per
    /// process, so the same person would be a different colour on every launch.
    public static func index(for key: String) -> Int {
        guard !key.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return Int(hash % UInt64(colours.count))
    }

    /// The colour value for a key, for callers that do not need the index.
    public static func colour(for key: String) -> UInt32 {
        colours[index(for: key)]
    }
}

extension String {
    /// Base URLs may or may not carry a trailing slash; paths always start with
    /// one, and `//api/files/...` is not the same path as `/api/files/...`.
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
