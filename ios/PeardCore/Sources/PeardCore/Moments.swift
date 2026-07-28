import Foundation

// MARK: - Descriptor

/// A moment as the UI draws it: the wire slug plus the emoji and label to show.
public struct Moment: Hashable, Sendable, Identifiable {
    /// Where the moment came from, which decides whether tapping it needs to
    /// create a `moment_kinds` row first.
    public enum Origin: Hashable, Sendable {
        /// Always available in every connection; needs no row.
        case builtin
        /// Recommended, but not yet added to this connection.
        case preset
        /// Added to this connection, so every member can see it.
        case custom(recordID: String?)
    }

    public let kind: EventKind
    public let emoji: String
    public let label: String
    public let origin: Origin

    public var id: String { kind.rawValue }

    /// True when logging this moment also has to publish it to the connection.
    public var needsPublishing: Bool {
        if case .preset = origin { return true }
        return false
    }

    public init(kind: EventKind, emoji: String, label: String, origin: Origin = .builtin) {
        self.kind = kind
        self.emoji = emoji
        self.label = label
        self.origin = origin
    }
}

// MARK: - Catalogue

/// The moments offered on the home screen: three built-ins that need no setup,
/// a recommended list to add from, and whatever a connection has invented.
///
/// Keep `builtin` in step with `server/internal/moments`, which is what the
/// widget feed and the push copy resolve against.
public enum MomentCatalogue {
    /// Shown for anything with no descriptor anywhere.
    public static let fallbackEmoji = "🍐"

    /// Available in every connection without being published first.
    public static let builtin: [Moment] = [
        Moment(kind: .beer, emoji: "🍺", label: "Beer"),
        Moment(kind: .loo, emoji: "💩", label: "Loo"),
        Moment(kind: .coffee, emoji: "☕", label: "Coffee"),
    ]

    /// Recommended additions, offered in the custom-moment sheet. Adding one
    /// publishes it to the connection so both sides draw it the same way.
    public static let presets: [Moment] = [
        Moment(kind: "tea", emoji: "🫖", label: "Tea", origin: .preset),
        Moment(kind: "water", emoji: "💧", label: "Water", origin: .preset),
        Moment(kind: "wine", emoji: "🍷", label: "Wine", origin: .preset),
        Moment(kind: "snack", emoji: "🍪", label: "Snack", origin: .preset),
        Moment(kind: "lunch", emoji: "🥪", label: "Lunch", origin: .preset),
        Moment(kind: "gym", emoji: "🏋️", label: "Gym", origin: .preset),
        Moment(kind: "run", emoji: "🏃", label: "Run", origin: .preset),
        Moment(kind: "walk", emoji: "🚶", label: "Walk", origin: .preset),
        Moment(kind: "commute", emoji: "🚆", label: "Commute", origin: .preset),
        Moment(kind: "nap", emoji: "😴", label: "Nap", origin: .preset),
        Moment(kind: "shower", emoji: "🚿", label: "Shower", origin: .preset),
        Moment(kind: "meds", emoji: "💊", label: "Meds", origin: .preset),
        Moment(kind: "smoke", emoji: "🚬", label: "Smoke", origin: .preset),
        Moment(kind: "chores", emoji: "🧺", label: "Chores", origin: .preset),
        Moment(kind: "work", emoji: "💻", label: "Work", origin: .preset),
        Moment(kind: "thinking_of_you", emoji: "🥰", label: "Thinking of you", origin: .preset),
    ]

    /// The moments a connection can log right now: the built-ins followed by
    /// its own published kinds, oldest first. A published kind whose slug
    /// matches a built-in replaces it, so a connection can re-label "loo"
    /// without ending up with two of them.
    public static func available(customKinds: [MomentKind]) -> [Moment] {
        var result = builtin
        var indexBySlug = Dictionary(
            uniqueKeysWithValues: result.enumerated().map { ($0.element.kind.rawValue, $0.offset) }
        )

        for kind in customKinds.sorted(by: MomentKind.byCreation) {
            let moment = kind.moment
            if let existing = indexBySlug[moment.kind.rawValue] {
                result[existing] = moment
            } else {
                indexBySlug[moment.kind.rawValue] = result.count
                result.append(moment)
            }
        }
        return result
    }

    /// The recommended moments a connection has not published yet.
    public static func unusedPresets(customKinds: [MomentKind]) -> [Moment] {
        let taken = Set(available(customKinds: customKinds).map(\.kind.rawValue))
        return presets.filter { !taken.contains($0.kind.rawValue) }
    }

    // MARK: Lookup

    public static func descriptor(for kind: EventKind?, customKinds: [MomentKind] = []) -> Moment? {
        guard let kind, !kind.isEmpty else { return nil }
        return available(customKinds: customKinds).first { $0.kind == kind }
    }

    public static func emoji(for kind: EventKind?, customKinds: [MomentKind] = []) -> String {
        descriptor(for: kind, customKinds: customKinds)?.emoji ?? fallbackEmoji
    }

    public static func label(for kind: EventKind?, customKinds: [MomentKind] = []) -> String {
        if let descriptor = descriptor(for: kind, customKinds: customKinds) { return descriptor.label }
        // An unpublished kind still reads better as its slug than as nothing.
        return kind.map(MomentSlug.humanised) ?? ""
    }

    /// Emoji for a post: the camera for photo posts, otherwise the moment's.
    public static func emoji(for post: Post, customKinds: [MomentKind] = []) -> String {
        switch post.type {
        case .photo: return "📸"
        default: return emoji(for: post.eventKind, customKinds: customKinds)
        }
    }
}

// MARK: - Slugs

/// Converts a typed label into a `posts.event_kind` slug, and back into
/// something readable when no descriptor is available.
public enum MomentSlug {
    /// `posts.event_kind` and `moment_kinds.slug` are both 40 characters.
    public static let maxLength = 40

    /// Used when a label has no slug-safe characters at all (for example an
    /// emoji-only label).
    public static let fallback = "moment"

    /// Lower-cases, strips diacritics and emoji, and joins the remaining words
    /// with underscores.
    public static func make(from label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            let isWordScalar = (scalar.value >= 97 && scalar.value <= 122) // a-z
                || (scalar.value >= 48 && scalar.value <= 57)             // 0-9
            if isWordScalar {
                if pendingSeparator, !slug.isEmpty { slug.append("_") }
                pendingSeparator = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
            if slug.count >= maxLength { break }
        }
        // Truncating can land immediately after a separator, which would leave
        // a trailing underscore and a trailing space in the humanised form.
        var trimmed = String(slug.prefix(maxLength))
        while trimmed.hasSuffix("_") { trimmed.removeLast() }
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// `thinking_of_you` -> `Thinking of you`, for a kind with no descriptor.
    public static func humanised(_ kind: EventKind) -> String {
        let words = kind.rawValue.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return kind.rawValue }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}

// MARK: - Emoji

/// Emoji handling for the custom-moment picker.
public enum MomentEmoji {
    /// Offered as a grid, so a moment can be given a face without opening the
    /// system emoji keyboard.
    public static let suggestions: [String] = [
        "🍺", "🍷", "🍸", "🥂", "☕", "🫖", "🧋", "💧",
        "🍪", "🍫", "🍕", "🥪", "🍜", "🍦", "🥗", "🍎",
        "💩", "🚿", "😴", "💊", "🚬", "🧺", "🧹", "🛒",
        "🏋️", "🏃", "🚶", "🧘", "🚴", "⚽", "🎾", "🏊",
        "💻", "📚", "🎧", "🎮", "🎬", "🎨", "✈️", "🚆",
        "❤️", "🥰", "😂", "🥳", "👋", "🙌", "🤝", "🍐",
    ]

    /// The first emoji in a string, or `nil` when there is none. Used to keep a
    /// single glyph from a text field the system emoji keyboard writes into.
    public static func first(in text: String) -> String? {
        for character in text where isEmoji(character) {
            return String(character)
        }
        return nil
    }

    /// True for a character iOS would render as emoji, including sequences that
    /// only become emoji through a variation selector (`❤️`) or a ZWJ join.
    public static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        // U+FE0F asks for the emoji rendering of an otherwise textual scalar;
        // U+200D joins a sequence that is emoji as a whole.
        return scalars.contains { $0.value == 0xFE0F || $0.value == 0x200D }
    }
}
