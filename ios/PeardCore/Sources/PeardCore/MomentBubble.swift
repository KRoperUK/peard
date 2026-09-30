import Foundation

/// The moment an iMessage bubble carries.
///
/// A bubble is an `MSMessage` whose URL is how it says what it is about: when
/// somebody with Pear'd taps it, Messages opens the tray with that message
/// selected, and the tray reads the moment back out to offer "log one too".
/// The URL is the server's own address with the moment in the query, because
/// on a device without the extension (a Mac, or a phone without Pear'd)
/// Messages opens the URL itself, and the site is the right place to land.
///
/// Deliberately only the moment — never the connection or the post. The bubble
/// goes into a thread with somebody who may not be in that connection, and
/// naming it would tell them who else you share with.
public struct MomentBubble: Equatable, Sendable {
    public let kind: EventKind
    public let emoji: String
    public let label: String

    public init(kind: EventKind, emoji: String, label: String) {
        self.kind = kind
        self.emoji = emoji
        self.label = label
    }

    private enum Query {
        static let kind = "peard_moment"
        static let emoji = "emoji"
        static let label = "label"
    }

    public var caption: String { "\(emoji) \(label) logged" }

    /// Said under the caption, to whoever the bubble reaches.
    public static let subcaption = "Tap to log one too"

    public func url(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: Query.kind, value: kind.rawValue),
            URLQueryItem(name: Query.emoji, value: emoji),
            URLQueryItem(name: Query.label, value: label),
        ]
        return components.url ?? base
    }

    /// The moment in a bubble's URL, or `nil` for anything else — an older
    /// bubble with no URL, or a message from another app entirely.
    public init?(url: URL?) {
        guard
            let url,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let kind = items.first(where: { $0.name == Query.kind })?.value, !kind.isEmpty
        else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        self.init(kind: EventKind(rawValue: kind), emoji: value(Query.emoji), label: value(Query.label))
    }
}
