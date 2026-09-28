import Foundation

/// A connection's timeline as a spreadsheet (issue #164).
///
/// The account export is JSON for everything, which answers "what do you hold
/// about me" but not "how many coffees did Sam and I have this year". This is
/// one connection, one row per moment, in a format any spreadsheet opens.
///
/// Quoting follows RFC 4180: a field is wrapped in double quotes when it holds a
/// comma, a double quote or a line break, and a double quote inside one is
/// doubled. Rows end in CRLF, as the RFC says. Notes are free text typed on a
/// phone, so every one of those turns up in practice.
public enum MomentsCSV {
    public static let header = ["date", "who", "moment", "note", "has_photo", "rewound"]

    /// A byte-order mark ahead of the header. Excel reads a CSV without one as
    /// the system's legacy encoding, which turns every moment's emoji and any
    /// accented name into mojibake; Numbers and Google Sheets skip it.
    static let byteOrderMark = "\u{FEFF}"

    /// The whole file, newest moment first, as the timeline reads.
    ///
    /// `authorLabel` is passed in rather than worked out here so the "who"
    /// column says exactly what the timeline does — see `Connection.authorLabel`.
    public static func make(
        posts: [Post],
        customKinds: [MomentKind],
        authorLabel: (String) -> String,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        let rows = posts.map { post in
            [
                // Local time with its offset, so a spreadsheet can chart by the
                // hour it happened where it happened, and nothing is ambiguous.
                post.hasTimestamp ? formatter.string(from: post.happenedAt) : "",
                authorLabel(post.author),
                moment(for: post, customKinds: customKinds),
                post.displayNote ?? "",
                post.hasMedia ? "yes" : "no",
                post.rewound ? "yes" : "no",
            ]
        }
        return byteOrderMark + ([header] + rows).map(row).joined()
    }

    /// Emoji and label together, as the timeline shows a moment.
    static func moment(for post: Post, customKinds: [MomentKind]) -> String {
        let emoji = MomentCatalogue.emoji(for: post, customKinds: customKinds)
        let label: String
        switch post.type {
        case .event: label = MomentCatalogue.label(for: post.eventKind, customKinds: customKinds)
        case .photo: label = "Photo"
        case .unknown(let value): label = value
        }
        return label.isEmpty ? emoji : "\(emoji) \(label)"
    }

    static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }

    static func field(_ value: String) -> String {
        // `unicodeScalars`, not `contains(_: Character)`: "\r\n" is a single
        // Character in Swift, so a Windows line break would slip past a search
        // for "\n" alone and split the row in two.
        let needsQuoting = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A name for the file that is safe on any filesystem the share sheet might
    /// hand it to: the connection's title can be anything somebody typed.
    public static func fileName(connectionTitle: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let title = connectionTitle.unicodeScalars
            .map { unsafe.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Pear'd moments.csv" : "Pear'd moments - \(title).csv"
    }

    /// Every post, a page at a time, until the last page says there are no more.
    ///
    /// Takes the fetch as a closure so the paging can be tested without a
    /// server. A moment logged while this runs pushes older ones a place down,
    /// so a row can appear at the bottom of one page and the top of the next;
    /// it is kept once.
    public static func collectPosts(
        fetchPage: (Int) async throws -> PostPage
    ) async throws -> [Post] {
        var posts: [Post] = []
        var seen = Set<String>()
        var page = 1
        while true {
            let result = try await fetchPage(page)
            for post in result.posts where seen.insert(post.id).inserted {
                posts.append(post)
            }
            // An empty page ends it too, whatever the totals say: a server
            // that miscounts must not keep this asking for pages forever.
            guard result.hasMore, !result.posts.isEmpty else { return posts }
            page = result.nextPage
        }
    }
}
