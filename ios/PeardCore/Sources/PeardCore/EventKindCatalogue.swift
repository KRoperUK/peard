import Foundation

public struct EventKindDescriptor: Hashable, Sendable, Identifiable {
    public let kind: EventKind
    public let emoji: String
    public let label: String

    public var id: String { kind.rawValue }

    public init(kind: EventKind, emoji: String, label: String) {
        self.kind = kind
        self.emoji = emoji
        self.label = label
    }
}

/// The ordered tally catalogue (Requirement 4.6).
public enum EventKindCatalogue {
    public static let all: [EventKindDescriptor] = [
        EventKindDescriptor(kind: .beer, emoji: "🍺", label: "Beer"),
        EventKindDescriptor(kind: .loo, emoji: "💩", label: "Loo"),
        EventKindDescriptor(kind: .coffee, emoji: "☕", label: "Coffee"),
    ]

    /// Emoji shown for anything outside the catalogue (Requirement 11.4).
    public static let fallbackEmoji = "🍐"

    public static func descriptor(for kind: EventKind?) -> EventKindDescriptor? {
        guard let kind else { return nil }
        return all.first { $0.kind == kind }
    }

    public static func emoji(for kind: EventKind?) -> String {
        descriptor(for: kind)?.emoji ?? fallbackEmoji
    }

    public static func label(for kind: EventKind?) -> String {
        descriptor(for: kind)?.label ?? kind?.rawValue ?? ""
    }

    /// Emoji for a post: the photo camera for photo posts, otherwise the
    /// tally emoji.
    public static func emoji(for post: Post) -> String {
        switch post.type {
        case .photo: return "📸"
        default: return emoji(for: post.eventKind)
        }
    }
}
