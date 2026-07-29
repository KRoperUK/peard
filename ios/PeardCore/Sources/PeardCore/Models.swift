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

/// A record in the `pairs` collection. A pair with more than two members is a
/// group; the collection kept its original name so no data migration was
/// needed when groups arrived.
public struct PairRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// Free text, set by any member. Empty for a 1:1 connection.
    public let name: String?
    public let created: Date

    public init(id: String, name: String? = nil, created: Date = .distantPast) {
        self.id = id
        self.name = name
        self.created = created
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        created = (try? container.decode(Date.self, forKey: .created)) ?? .distantPast
    }

    public var displayName: String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}

/// A record in the `moment_kinds` collection: one custom moment, shared by every
/// member of a connection so they all draw it the same way.
public struct MomentKind: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pair: String
    public let slug: EventKind
    public let emoji: String
    public let label: String
    public let createdBy: String?
    public let created: Date

    enum CodingKeys: String, CodingKey {
        case id, pair, slug, emoji, label, created
        case createdBy = "created_by"
    }

    public init(
        id: String,
        pair: String,
        slug: EventKind,
        emoji: String,
        label: String,
        createdBy: String? = nil,
        created: Date = .distantPast
    ) {
        self.id = id
        self.pair = pair
        self.slug = slug
        self.emoji = emoji
        self.label = label
        self.createdBy = createdBy
        self.created = created
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pair = try container.decode(String.self, forKey: .pair)
        slug = try container.decode(EventKind.self, forKey: .slug)
        emoji = try container.decode(String.self, forKey: .emoji)
        label = try container.decode(String.self, forKey: .label)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        created = (try? container.decode(Date.self, forKey: .created)) ?? .distantPast
    }

    /// How the UI draws this kind.
    public var moment: Moment {
        Moment(
            kind: slug,
            emoji: emoji.isEmpty ? MomentCatalogue.fallbackEmoji : emoji,
            label: label.isEmpty ? MomentSlug.humanised(slug) : label,
            origin: .custom(recordID: id)
        )
    }

    /// Oldest first, so the home screen's order is stable as kinds are added.
    public static func byCreation(_ lhs: MomentKind, _ rhs: MomentKind) -> Bool {
        lhs.created == rhs.created ? lhs.id < rhs.id : lhs.created < rhs.created
    }
}

/// A connection as the app presents it: the `pairs` row, the signed-in user's
/// role in it, and who else is in it.
///
/// Decoded from `GET /api/peard/connections`, which resolves the other members'
/// display names server-side. The `users` view rule hides those records from the
/// client, so without that route every unnamed connection would be titled
/// "Partner" and a switcher with several of them would be unusable.
public struct Connection: Codable, Hashable, Sendable, Identifiable {
    public struct Member: Codable, Hashable, Sendable, Identifiable {
        public let user: String
        public let name: String
        public let role: MemberRole
        public let isYou: Bool
        /// Stored filename of their profile photo, empty when they have none.
        public let avatarFilename: String?

        public var id: String { user }

        enum CodingKeys: String, CodingKey {
            case user, name, role
            case isYou = "is_you"
            case avatarFilename = "avatar"
        }

        public init(
            user: String,
            name: String,
            role: MemberRole = .member,
            isYou: Bool = false,
            avatarFilename: String? = nil
        ) {
            self.user = user
            self.name = name
            self.role = role
            self.isYou = isYou
            self.avatarFilename = avatarFilename
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            user = try container.decode(String.self, forKey: .user)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? PartnerLabel.unknown
            role = try container.decodeIfPresent(MemberRole.self, forKey: .role) ?? .member
            isYou = try container.decodeIfPresent(Bool.self, forKey: .isYou) ?? false
            avatarFilename = try container.decodeIfPresent(String.self, forKey: .avatarFilename)
        }

        /// Their photo, or the initials to draw instead.
        public var avatar: Avatar {
            Avatar(
                owner: .users,
                recordID: user,
                filename: avatarFilename,
                placeholder: .make(name: name, key: user)
            )
        }
    }

    /// The `pairs` record id.
    public let pair: String
    /// The name somebody gave the connection. Empty for an unnamed 1:1.
    public let name: String?
    public let created: Date
    public let role: MemberRole
    public let memberCount: Int
    public let members: [Member]
    /// True when the signed-in user has silenced this connection's pushes. Per
    /// membership, not per user: silencing the noisy group leaves the 1:1 audible.
    public let isMuted: Bool
    /// Stored filename of the connection's own photo, empty when it has none.
    /// A group's photo; a 1:1 may also have one, and when it does not the rail
    /// falls back to the other person's.
    public let avatarFilename: String?

    public var id: String { pair }

    enum CodingKeys: String, CodingKey {
        case pair, name, created, role, members
        case memberCount = "member_count"
        case isMuted = "muted"
        case avatarFilename = "avatar"
    }

    public init(
        pair: String,
        name: String? = nil,
        created: Date = .distantPast,
        role: MemberRole = .member,
        memberCount: Int? = nil,
        members: [Member] = [],
        isMuted: Bool = false,
        avatarFilename: String? = nil
    ) {
        self.pair = pair
        self.name = name
        self.created = created
        self.role = role
        self.members = members
        self.memberCount = memberCount ?? max(members.count, 1)
        self.isMuted = isMuted
        self.avatarFilename = avatarFilename
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pair = try container.decode(String.self, forKey: .pair)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        created = (try? container.decode(Date.self, forKey: .created)) ?? .distantPast
        role = try container.decodeIfPresent(MemberRole.self, forKey: .role) ?? .member
        members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        avatarFilename = try container.decodeIfPresent(String.self, forKey: .avatarFilename)
        let count = try container.decodeIfPresent(Int.self, forKey: .memberCount)
        // A connection always contains at least the signed-in user.
        memberCount = max(count ?? members.count, 1)
    }

    /// True when the signed-in user owns the connection, and so may remove
    /// somebody from it.
    public var isOwnedByMe: Bool { role == .owner }

    /// More than two people makes it a group.
    public var isGroup: Bool { memberCount > 2 }

    /// The name somebody set, when they set one.
    public var displayName: String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    /// Everybody except the signed-in user.
    public var others: [Member] { members.filter { !$0.isYou } }

    /// The other person's name in a 1:1, `nil` in a group or when unknown.
    public var partnerName: String? {
        guard !isGroup, others.count == 1 else { return nil }
        return others[0].name
    }

    /// True when you are the only member left.
    ///
    /// Reachable in ordinary use: leaving removes a membership row and nothing
    /// deletes the connection behind it, so the last person standing keeps a
    /// connection containing only themselves — with everybody's moments still in
    /// it. Every label that assumed "not a group means two of us" was wrong here.
    public var isJustYou: Bool { memberCount <= 1 && others.isEmpty }

    /// The connection's title, in precedence order: the name somebody set, the
    /// other person's name for a 1:1, the other members for a small group, then
    /// a description of its size.
    public func title() -> String {
        if let displayName { return displayName }
        if let partnerName { return partnerName }
        let names = others.map(\.name)
        switch names.count {
        // No names *and* nobody else to name: this connection is just you. Distinct
        // from the case below, where there is somebody but the server could not
        // resolve them, and "Partner" is the right guess.
        case 0 where isJustYou: return Self.justYouTitle
        case 0: return PartnerLabel.fallback
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]) +\(names.count - 1)"
        }
    }

    /// Sub-label under the title in the connection switcher.
    public var subtitle: String {
        if isJustYou { return Self.justYouTitle }
        return isGroup ? "\(memberCount) people" : "Just the two of you"
    }

    static let justYouTitle = "Just you"

    /// What to call everybody who is not you — the second tally row, and the
    /// "others" side of a moment breakdown.
    ///
    /// Three cases rather than two. A group has no single partner, so "Others". A
    /// 1:1 uses the other person's name. But a connection can also have no other
    /// *current* member while still carrying their moments: leaving deletes the
    /// membership row, not the posts. There "Partner" is wrong twice over — there
    /// is no partner, and `PartnerLabel.unknown` is already what the timeline
    /// calls that same author. Two screens naming one person differently is worse
    /// than either name on its own.
    public var othersLabel: String {
        if isGroup { return "Others" }
        guard let other = others.first else { return PartnerLabel.unknown }
        return other.name
    }

    /// The display name for a post's author.
    public func name(forUser userID: String) -> String? {
        members.first { $0.user == userID }?.name
    }

    /// What to draw for this connection in the rail.
    ///
    /// A connection's own photo wins. Failing that, a 1:1 borrows the other
    /// person's — the connection *is* that person, and making somebody upload the
    /// same picture twice to see a face would be silly. A group with no photo
    /// falls back to initials of its title, with `isGroup` set so the UI can
    /// choose a group glyph instead.
    public var avatar: Avatar {
        if let avatarFilename, !avatarFilename.isEmpty {
            return Avatar(
                owner: .pairs,
                recordID: pair,
                filename: avatarFilename,
                placeholder: .make(name: title(), key: pair, isGroup: isGroup)
            )
        }
        if !isGroup, let other = others.first, other.avatar.hasImage {
            return other.avatar
        }
        return Avatar(
            owner: .pairs,
            recordID: pair,
            filename: nil,
            placeholder: .make(name: title(), key: pair, isGroup: isGroup)
        )
    }

    /// True when somebody has set a photo on the connection itself, as opposed to
    /// the rail borrowing a member's. Distinguishes "remove the group photo" from
    /// "there is nothing to remove".
    public var hasOwnAvatar: Bool {
        guard let avatarFilename else { return false }
        return !avatarFilename.isEmpty
    }
}

/// Response of `GET /api/peard/connections`.
public struct ConnectionList: Codable, Hashable, Sendable {
    public let connections: [Connection]
    public init(connections: [Connection]) { self.connections = connections }
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
    /// Present when the invite adds the accepting user to an existing
    /// connection rather than creating a new one.
    public let pair: String?

    enum CodingKeys: String, CodingKey {
        case code, expires, pair
        case deepLink = "deep_link"
    }

    public init(code: String, expires: Date, deepLink: String, pair: String? = nil) {
        self.code = code
        self.expires = expires
        self.deepLink = deepLink
        self.pair = pair
    }

    /// True when accepting joins an existing group.
    public var isGroupInvite: Bool {
        guard let pair else { return false }
        return !pair.isEmpty
    }

    /// Text shared by the invite share action (Requirement 10.2).
    public var shareMessage: String {
        isGroupInvite
            ? "Join my group on Pear'd! Code: \(code)\n\(deepLink)"
            : "Pear up with me on Pear'd! Code: \(code)\n\(deepLink)"
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

    /// Which connection the feed is showing. A user may belong to several, and
    /// the server picks whichever somebody else posted in most recently.
    public struct ConnectionInfo: Codable, Hashable, Sendable {
        public let id: String?
        public let name: String?
        public let memberCount: Int?
        public let isGroup: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name
            case memberCount = "member_count"
            case isGroup = "is_group"
        }

        public init(id: String? = nil, name: String? = nil, memberCount: Int? = nil, isGroup: Bool? = nil) {
            self.id = id
            self.name = name
            self.memberCount = memberCount
            self.isGroup = isGroup
        }

        public var displayName: String? {
            guard let name, !name.isEmpty else { return nil }
            return name
        }
    }

    /// One moment kind's count for today, with the emoji resolved server-side so
    /// the widget does not need the connection's catalogue.
    public struct Tally: Codable, Hashable, Sendable, Identifiable {
        public let kind: EventKind
        public let emoji: String
        public let label: String
        public let count: Int

        public var id: String { kind.rawValue }

        public init(kind: EventKind, emoji: String, label: String, count: Int) {
            self.kind = kind
            self.emoji = emoji
            self.label = label
            self.count = count
        }
    }

    /// The original two-count shape, kept so a widget build that predates
    /// generalised tallies keeps rendering.
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
        /// Resolved server-side, so a custom moment arrives ready to draw.
        public let emoji: String?
        public let label: String?
        public let note: String?
        /// Absent for records that predate the server's `created` field.
        public let created: Date?
        public let mediaURL: String?
        public let author: String?

        enum CodingKeys: String, CodingKey {
            case id, type, note, created, author, emoji, label
            case eventKind = "event_kind"
            case mediaURL = "media_url"
        }

        public init(
            id: String,
            type: PostType,
            eventKind: EventKind? = nil,
            emoji: String? = nil,
            label: String? = nil,
            note: String? = nil,
            created: Date? = nil,
            mediaURL: String? = nil,
            author: String? = nil
        ) {
            self.id = id
            self.type = type
            self.eventKind = eventKind
            self.emoji = emoji
            self.label = label
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
            emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            label = try container.decodeIfPresent(String.self, forKey: .label)
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

        /// The server's emoji when it sent one, else the local catalogue's.
        public var displayEmoji: String {
            if type == .photo { return "📸" }
            if let emoji, !emoji.isEmpty { return emoji }
            return MomentCatalogue.emoji(for: eventKind)
        }

        public var displayLabel: String {
            if let label, !label.isEmpty { return label }
            return MomentCatalogue.label(for: eventKind)
        }
    }

    /// One moment the widget's own buttons may log, resolved server-side so the
    /// extension does not need the connection's catalogue.
    public struct AvailableMoment: Codable, Hashable, Sendable, Identifiable {
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

    public let state: FeedState
    public let partner: Partner?
    public let connection: ConnectionInfo?
    public let counts: Counts?
    public let tallies: [Tally]?
    public let post: FeedPost?
    /// Absent on a server that predates interactive widget buttons.
    public let moments: [AvailableMoment]?

    public init(
        state: FeedState,
        partner: Partner? = nil,
        connection: ConnectionInfo? = nil,
        counts: Counts? = nil,
        tallies: [Tally]? = nil,
        post: FeedPost? = nil,
        moments: [AvailableMoment]? = nil
    ) {
        self.state = state
        self.partner = partner
        self.connection = connection
        self.counts = counts
        self.tallies = tallies
        self.post = post
        self.moments = moments
    }

    /// The moments to offer as buttons, falling back to the built-ins so a widget
    /// talking to an older server still has something to tap.
    public var buttonMoments: [AvailableMoment] {
        if let moments, !moments.isEmpty { return moments }
        return MomentCatalogue.builtin.map {
            AvailableMoment(kind: $0.kind, emoji: $0.emoji, label: $0.label)
        }
    }

    public var partnerName: String { partner?.name ?? PartnerLabel.fallback }
    public var beerCount: Int { counts?.beer ?? 0 }
    public var looCount: Int { counts?.loo ?? 0 }

    /// True when the moment came from a group rather than a 1:1 connection.
    public var isGroup: Bool { connection?.isGroup ?? false }

    /// The group's name, only when it is a group that has been named.
    public var groupName: String? {
        guard isGroup else { return nil }
        return connection?.displayName
    }

    /// Today's tallies, most frequent first, falling back to the legacy
    /// beer/loo counts when the server predates the generalised field.
    public var displayTallies: [Tally] {
        if let tallies, !tallies.isEmpty { return tallies }
        var legacy: [Tally] = []
        if beerCount > 0 {
            legacy.append(Tally(kind: .beer, emoji: "🍺", label: "Beer", count: beerCount))
        }
        if looCount > 0 {
            legacy.append(Tally(kind: .loo, emoji: "💩", label: "Loo", count: looCount))
        }
        return legacy
    }
}

/// Response of `GET /api/peard/widget/connections`.
///
/// Thinner than `Connection` on purpose: a configurable widget's picker needs an
/// id and something to call it, and this endpoint is reachable with the widget
/// token rather than a PocketBase session — which the extension does not have.
public struct WidgetConnection: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let memberCount: Int
    public let isGroup: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case memberCount = "member_count"
        case isGroup = "is_group"
    }

    public init(id: String, title: String, memberCount: Int = 2, isGroup: Bool = false) {
        self.id = id
        self.title = title
        self.memberCount = memberCount
        self.isGroup = isGroup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? PartnerLabel.fallback
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount) ?? 2
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
    }

    public var subtitle: String {
        isGroup ? "\(memberCount) people" : "Just the two of you"
    }
}

/// Response of `GET /api/peard/widget/connections`.
public struct WidgetConnectionList: Codable, Hashable, Sendable {
    public let connections: [WidgetConnection]
    public init(connections: [WidgetConnection]) { self.connections = connections }
}

/// Response of `POST /api/peard/widget/moment`.
public struct WidgetMomentResult: Codable, Hashable, Sendable {
    public let id: String
    public let pair: String
    public let kind: EventKind
    public let emoji: String?
    public let label: String?

    public init(id: String, pair: String, kind: EventKind, emoji: String? = nil, label: String? = nil) {
        self.id = id
        self.pair = pair
        self.kind = kind
        self.emoji = emoji
        self.label = label
    }
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

/// Response of `POST`/`DELETE /api/peard/connections/avatar`.
///
/// Only the connection's own filename comes back; the rest of the connection is
/// unchanged, and the caller re-reads the list anyway so every screen agrees.
public struct ConnectionAvatar: Codable, Hashable, Sendable {
    public let pair: String
    public let avatarFilename: String?

    enum CodingKeys: String, CodingKey {
        case pair
        case avatarFilename = "avatar"
    }

    public init(pair: String, avatarFilename: String? = nil) {
        self.pair = pair
        self.avatarFilename = avatarFilename
    }
}

/// Response of `GET`/`POST /api/peard/profile`.
///
/// Distinct from `UserRecord`: this route is the caller reading and writing their
/// own record, so `display_name` is always present (empty when unset) rather than
/// optional-because-hidden-by-a-view-rule.
public struct UserProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let email: String?
    /// Stored filename of the caller's own photo, empty when they have none.
    public let avatarFilename: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarFilename = "avatar"
    }

    public init(id: String, displayName: String = "", email: String? = nil, avatarFilename: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.avatarFilename = avatarFilename
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        avatarFilename = try container.decodeIfPresent(String.self, forKey: .avatarFilename)
    }

    /// What other members would see today: the set name, else the email's local
    /// part, else the neutral fallback. Mirrors the server's own resolution.
    public var effectiveName: String {
        PartnerLabel.resolve(displayName: displayName.isEmpty ? nil : displayName, email: email)
    }

    /// The caller's own photo, or the initials to draw instead.
    public var avatar: Avatar {
        Avatar(
            owner: .users,
            recordID: id,
            filename: avatarFilename,
            placeholder: .make(name: effectiveName, key: id)
        )
    }

    /// True when there is a photo to offer removing.
    public var hasAvatar: Bool {
        guard let avatarFilename else { return false }
        return !avatarFilename.isEmpty
    }
}

/// One page of a connection's timeline.
public struct PostPage: Hashable, Sendable {
    public let posts: [Post]
    public let page: Int
    public let totalPages: Int
    public let totalItems: Int

    public init(posts: [Post], page: Int, totalPages: Int, totalItems: Int) {
        self.posts = posts
        self.page = page
        self.totalPages = totalPages
        self.totalItems = totalItems
    }

    /// True when another page exists. Uses the page number rather than "did this
    /// page come back full", which would ask for an empty page whenever the total
    /// happened to be an exact multiple of the page size.
    public var hasMore: Bool { page < totalPages }

    public var nextPage: Int { page + 1 }
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
