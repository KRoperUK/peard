import Foundation

// MARK: - Open enumerations

/// An enumeration that decodes unrecognised wire values into an `unknown` case
/// preserving the original string, so a server-side addition cannot break
/// decoding and cannot lose information on re-encode (Requirement 4.7, 4.8).
public protocol OpenEnum: Codable, Hashable, Sendable, CustomStringConvertible {
    init(rawValue: String)
    var rawValue: String { get }
}

public extension OpenEnum {
    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

public enum PostType: OpenEnum {
    case photo
    case event
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "photo": self = .photo
        case "event": self = .event
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .photo: return "photo"
        case .event: return "event"
        case .unknown(let value): return value
        }
    }
}

public enum MemberRole: OpenEnum {
    case owner
    case member
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "member": self = .member
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .member: return "member"
        case .unknown(let value): return value
        }
    }
}

public enum ReactionKind: OpenEnum, CaseIterable {
    case cheers
    case plusOne
    case heart
    case unknown(String)

    /// Only the known kinds are offered in the UI.
    public static var allCases: [ReactionKind] { [.cheers, .plusOne, .heart] }

    public init(rawValue: String) {
        switch rawValue {
        case "cheers": self = .cheers
        case "plus_one": self = .plusOne
        case "heart": self = .heart
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .cheers: return "cheers"
        case .plusOne: return "plus_one"
        case .heart: return "heart"
        case .unknown(let value): return value
        }
    }

    public var emoji: String {
        switch self {
        case .cheers: return "🍻"
        case .plusOne: return "👏"
        case .heart: return "❤️"
        case .unknown: return "🍐"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .cheers: return "Cheers"
        case .plusOne: return "Plus one"
        case .heart: return "Heart"
        case .unknown(let value): return value
        }
    }
}

public enum FeedState: OpenEnum {
    case ok
    case empty
    case unpaired
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "ok": self = .ok
        case "empty": self = .empty
        case "unpaired": self = .unpaired
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .ok: return "ok"
        case .empty: return "empty"
        case .unpaired: return "unpaired"
        case .unknown(let value): return value
        }
    }
}

/// The server column is free-text (`event_kind`, max 40 characters), so this is
/// an open string wrapper rather than a closed enumeration.
public struct EventKind: OpenEnum, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var isEmpty: Bool { rawValue.isEmpty }

    public static let beer = EventKind(rawValue: "beer")
    public static let loo = EventKind(rawValue: "loo")
    public static let coffee = EventKind(rawValue: "coffee")
}

// MARK: - Records

/// A record in the `posts` collection.
public struct Post: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pair: String
    public let author: String
    public let type: PostType
    public let eventKind: EventKind?
    public let note: String?
    public let media: String?
    public let created: Date

    enum CodingKeys: String, CodingKey {
        case id, pair, author, type, note, media, created
        case eventKind = "event_kind"
    }

    public init(
        id: String,
        pair: String,
        author: String,
        type: PostType,
        eventKind: EventKind? = nil,
        note: String? = nil,
        media: String? = nil,
        created: Date
    ) {
        self.id = id
        self.pair = pair
        self.author = author
        self.type = type
        self.eventKind = eventKind
        self.note = note
        self.media = media
        self.created = created
    }

    /// Records created before the server gained its `created` autodate field
    /// carry no timestamp. One such row must not fail the whole list, so it
    /// decodes as `distantPast` — it then sorts last and counts only towards
    /// the all-time tally.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pair = try container.decode(String.self, forKey: .pair)
        author = try container.decode(String.self, forKey: .author)
        type = try container.decode(PostType.self, forKey: .type)
        eventKind = try container.decodeIfPresent(EventKind.self, forKey: .eventKind)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        media = try container.decodeIfPresent(String.self, forKey: .media)
        created = (try? container.decode(Date.self, forKey: .created)) ?? .distantPast
    }

    /// True when this post carries a real server timestamp.
    public var hasTimestamp: Bool { created != .distantPast }

    /// The `note` value only when it carries text (Requirement 11.2).
    public var displayNote: String? {
        guard let note, !note.isEmpty else { return nil }
        return note
    }

    /// True when the post is a photo with an attached file (Requirement 11.3).
    public var hasMedia: Bool {
        guard let media else { return false }
        return !media.isEmpty
    }

    /// Path of the 512-point thumbnail for this post's attachment.
    public func mediaThumbnailPath() -> String? {
        guard hasMedia, let media else { return nil }
        let escaped = media.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? media
        return "/api/files/posts/\(id)/\(escaped)?thumb=512x512"
    }
}

/// A record in the `pair_members` collection.
public struct PairMember: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pair: String
    public let user: String
    public let role: MemberRole
    /// Populated only when the request asks for `expand=user` *and* the users
    /// collection view rule allows reading the record.
    public let expand: Expand?

    public struct Expand: Codable, Hashable, Sendable {
        public let user: UserRecord?
        public init(user: UserRecord?) { self.user = user }
    }

    public init(id: String, pair: String, user: String, role: MemberRole, expand: Expand? = nil) {
        self.id = id
        self.pair = pair
        self.user = user
        self.role = role
        self.expand = expand
    }
}

/// A record in the `reactions` collection.
public struct Reaction: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let post: String
    public let user: String
    public let kind: ReactionKind

    public init(id: String, post: String, user: String, kind: ReactionKind) {
        self.id = id
        self.post = post
        self.user = user
        self.kind = kind
    }
}

/// A record in the `devices` collection.
public struct Device: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let user: String
    public let platform: String
    public let pushToken: String

    enum CodingKeys: String, CodingKey {
        case id, user, platform
        case pushToken = "push_token"
    }

    public init(id: String, user: String, platform: String, pushToken: String) {
        self.id = id
        self.user = user
        self.platform = platform
        self.pushToken = pushToken
    }
}

/// A `users` record, as returned by the auth endpoints.
public struct UserRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let email: String?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
    }

    public init(id: String, email: String? = nil, displayName: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}

// MARK: - Custom route payloads

/// Response of `POST /api/peard/pairs/invite`.
public struct PairInvite: Codable, Hashable, Sendable {
    public let code: String
    public let expires: Date
    public let deepLink: String

    enum CodingKeys: String, CodingKey {
        case code, expires
        case deepLink = "deep_link"
    }

    public init(code: String, expires: Date, deepLink: String) {
        self.code = code
        self.expires = expires
        self.deepLink = deepLink
    }

    /// Text shared by the invite share action (Requirement 10.2).
    public var shareMessage: String {
        "Pear up with me on Pear'd! Code: \(code)\n\(deepLink)"
    }
}

/// Response of `POST /api/peard/pairs/accept`.
public struct PairAcceptance: Codable, Hashable, Sendable {
    public let pair: String
    public init(pair: String) { self.pair = pair }
}

/// Response of `POST /api/peard/widget/token`.
public struct WidgetTokenIssue: Codable, Hashable, Sendable {
    public let id: String?
    public let token: String
    public init(id: String? = nil, token: String) {
        self.id = id
        self.token = token
    }
}

/// Response of `GET /api/peard/widget/feed`.
public struct WidgetFeed: Codable, Hashable, Sendable {
    public struct Partner: Codable, Hashable, Sendable {
        public let name: String
        public init(name: String) { self.name = name }
    }

    public struct Counts: Codable, Hashable, Sendable {
        public let beer: Int
        public let loo: Int
        public init(beer: Int, loo: Int) {
            self.beer = beer
            self.loo = loo
        }
    }

    public struct FeedPost: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let type: PostType
        public let eventKind: EventKind?
        public let note: String?
        /// Absent for records that predate the server's `created` field.
        public let created: Date?
        public let mediaURL: String?
        public let author: String?

        enum CodingKeys: String, CodingKey {
            case id, type, note, created, author
            case eventKind = "event_kind"
            case mediaURL = "media_url"
        }

        public init(
            id: String,
            type: PostType,
            eventKind: EventKind? = nil,
            note: String? = nil,
            created: Date? = nil,
            mediaURL: String? = nil,
            author: String? = nil
        ) {
            self.id = id
            self.type = type
            self.eventKind = eventKind
            self.note = note
            self.created = created
            self.mediaURL = mediaURL
            self.author = author
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(PostType.self, forKey: .type)
            eventKind = try container.decodeIfPresent(EventKind.self, forKey: .eventKind)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            created = try? container.decode(Date.self, forKey: .created)
            mediaURL = try container.decodeIfPresent(String.self, forKey: .mediaURL)
            author = try container.decodeIfPresent(String.self, forKey: .author)
        }

        public var hasMedia: Bool {
            guard let mediaURL else { return false }
            return !mediaURL.isEmpty
        }

        public var displayNote: String? {
            guard let note, !note.isEmpty else { return nil }
            return note
        }
    }

    public let state: FeedState
    public let partner: Partner?
    public let counts: Counts?
    public let post: FeedPost?

    public init(state: FeedState, partner: Partner? = nil, counts: Counts? = nil, post: FeedPost? = nil) {
        self.state = state
        self.partner = partner
        self.counts = counts
        self.post = post
    }

    public var partnerName: String { partner?.name ?? "Partner" }
    public var beerCount: Int { counts?.beer ?? 0 }
    public var looCount: Int { counts?.loo ?? 0 }
}

/// Response of the auth endpoints (`/api/peard/auth/apple`,
/// `/api/collections/users/auth-with-oauth2`, `auth-with-password`).
public struct AuthResponse: Codable, Hashable, Sendable {
    public let token: String
    public let record: UserRecord
    public init(token: String, record: UserRecord) {
        self.token = token
        self.record = record
    }
}

/// PocketBase paged list envelope.
public struct RecordList<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let page: Int?
    public let perPage: Int?
    public let totalItems: Int?
    public let totalPages: Int?
    public let items: [Item]

    public init(items: [Item], page: Int? = nil, perPage: Int? = nil, totalItems: Int? = nil, totalPages: Int? = nil) {
        self.items = items
        self.page = page
        self.perPage = perPage
        self.totalItems = totalItems
        self.totalPages = totalPages
    }
}
