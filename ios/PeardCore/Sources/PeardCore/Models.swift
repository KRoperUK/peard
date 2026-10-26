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
    /// Only words: a reply typed into a moment's notification. Not an event,
    /// so it counts in no tally.
    case note
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "photo": self = .photo
        case "event": self = .event
        case "note": self = .note
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .photo: return "photo"
        case .event: return "event"
        case .note: return "note"
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
    /// The one moment that carries an amount; see `WaterAmount`.
    public static let water = EventKind(rawValue: "water")
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
    /// When the record was last written. Equal to `created` until somebody
    /// edits the moment, which is what `isEdited` reads.
    public let updated: Date
    /// When the moment happened, which is what the timeline sorts by and what
    /// the tallies count. Equal to `created` unless somebody rewound it; see
    /// `Rewind`. Unread still reads `created`, because a moment logged late is
    /// still news.
    public let happenedAt: Date
    /// Somebody picked this moment's time, rather than it arriving late from the
    /// offline queue. Drives the "Rewound" chip; see `Rewind`.
    public let rewound: Bool
    /// The photo this post answers — a comment typed under it, or a photo sent
    /// back. `nil` for everything else, including an answer whose photo has
    /// since been deleted: the server empties the relation then.
    public let replyTo: String?
    /// How much, in the kind's canonical unit — millilitres of water, steps,
    /// exercise minutes — for a moment that carries one. `nil` for every
    /// moment that has no amount to give: the server stores those as 0, which
    /// is not an amount.
    public let amount: Int?

    enum CodingKeys: String, CodingKey {
        case id, pair, author, type, note, media, created, updated, rewound, amount
        case eventKind = "event_kind"
        case happenedAt = "happened_at"
        case replyTo = "reply_to"
    }

    /// The wire's sanity ceiling for an amount, mirroring the server's posts
    /// bound: one entry cannot be absurd, but the bound is not any one
    /// metric's — water's five litres must not drop a steps count in the
    /// thousands (#437).
    public static let wireAmountMaximum = 1_000_000

    /// An amount worth keeping from storage or the wire: positive, and within
    /// the wire ceiling. The server's 0 for "none" becomes nil.
    public static func normalisedAmount(_ amount: Int?) -> Int? {
        guard let amount, amount > 0, amount <= wireAmountMaximum else { return nil }
        return amount
    }

    public init(
        id: String,
        pair: String,
        author: String,
        type: PostType,
        eventKind: EventKind? = nil,
        note: String? = nil,
        media: String? = nil,
        created: Date,
        updated: Date? = nil,
        happenedAt: Date? = nil,
        rewound: Bool? = nil,
        replyTo: String? = nil,
        amount: Int? = nil
    ) {
        self.id = id
        self.pair = pair
        self.replyTo = replyTo
        self.amount = Self.normalisedAmount(amount)
        self.author = author
        self.type = type
        self.eventKind = eventKind
        self.note = note
        self.media = media
        self.created = created
        // Defaults to `created` rather than to a sentinel: a caller that does
        // not mention `updated` is describing a moment nobody has edited.
        self.updated = updated ?? created
        self.happenedAt = happenedAt ?? created
        self.rewound = rewound ?? Rewind.isRewound(self.happenedAt, loggedAt: created)
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
        let created = (try? container.decode(Date.self, forKey: .created)) ?? .distantPast
        self.created = created
        // Absent on a server predating the timestamps migration, and on the
        // widget's trimmed payloads. Falling back to `created` means such a post
        // reads as unedited rather than as edited-in-1970.
        updated = (try? container.decode(Date.self, forKey: .updated)) ?? created
        // Absent on a server predating rewinding: every moment then happened
        // when it was logged.
        let happenedAt = (try? container.decode(Date.self, forKey: .happenedAt)) ?? created
        self.happenedAt = happenedAt
        // A server from before the field existed had only the gap to go on,
        // and back then every gap was a picked time.
        rewound = (try? container.decodeIfPresent(Bool.self, forKey: .rewound))
            ?? (created != .distantPast && Rewind.isRewound(happenedAt, loggedAt: created))
        // PocketBase sends an unset relation as "", which is not a post.
        let replyTo = try? container.decodeIfPresent(String.self, forKey: .replyTo)
        self.replyTo = replyTo?.isEmpty == false ? replyTo : nil
        // Absent on a server predating amounts, and 0 on every moment without
        // one; neither is an amount.
        amount = Self.normalisedAmount(try? container.decodeIfPresent(Int.self, forKey: .amount))
    }

    /// True when this post carries a real server timestamp.
    public var hasTimestamp: Bool { created != .distantPast }


    /// Whether this moment has been changed since it was logged.
    ///
    /// A tolerance rather than `updated > created`, because the two are written
    /// in the same breath at creation and the database keeps them to the
    /// millisecond — a create whose two stamps land either side of a tick would
    /// otherwise show up as an edit nobody made. Nothing a person does within
    /// two seconds of logging a moment is worth labelling anyway.
    public var isEdited: Bool {
        hasTimestamp && updated.timeIntervalSince(created) > 2
    }

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

    /// Path of a thumbnail of this post's attachment — 512 unless asked
    /// otherwise; see `PhotoThumb`.
    public func mediaThumbnailPath(_ thumb: PhotoThumb = .medium) -> String? {
        guard let escaped = escapedMediaFilename else { return nil }
        return "/api/files/posts/\(id)/\(escaped)?thumb=\(thumb.rawValue)"
    }

    /// Path of the attachment at the size it was uploaded.
    ///
    /// Only for a viewer that fills the screen. Everywhere else wants the
    /// thumbnail: these are camera photos, and pulling several megabytes to
    /// draw a 36-point row is slow on the timeline and rude on a phone plan.
    public func mediaPath() -> String? {
        guard let escaped = escapedMediaFilename else { return nil }
        return "/api/files/posts/\(id)/\(escaped)"
    }

    private var escapedMediaFilename: String? {
        guard hasMedia, let media else { return nil }
        return media.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? media
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
    /// Moments other people have posted here since you last opened it.
    ///
    /// Server-counted, per connection, and never includes your own moments —
    /// logging something is not news to the person who logged it. Muted
    /// connections still report a count: muting silences the alert, it does not
    /// mean "stop telling me anything happened".
    public let unreadCount: Int
    /// The cut-off `unreadCount` was counted from — the last time you opened
    /// this connection, or the day you joined it if you never have.
    ///
    /// Carried so the timeline can show *which* moments are new, not just how
    /// many. The server sends the effective value rather than a bare
    /// `last_seen_at` that might be absent, so the join-date fallback is
    /// applied in exactly one place.
    public let lastSeenAt: Date?

    public var id: String { pair }

    enum CodingKeys: String, CodingKey {
        case pair, name, created, role, members
        case memberCount = "member_count"
        case isMuted = "muted"
        case avatarFilename = "avatar"
        case unreadCount = "unread"
        case lastSeenAt = "last_seen_at"
    }

    public init(
        pair: String,
        name: String? = nil,
        created: Date = .distantPast,
        role: MemberRole = .member,
        memberCount: Int? = nil,
        members: [Member] = [],
        isMuted: Bool = false,
        avatarFilename: String? = nil,
        unreadCount: Int = 0,
        lastSeenAt: Date? = nil
    ) {
        self.pair = pair
        self.name = name
        self.created = created
        self.role = role
        self.members = members
        self.memberCount = memberCount ?? max(members.count, 1)
        self.isMuted = isMuted
        self.avatarFilename = avatarFilename
        self.unreadCount = unreadCount
        self.lastSeenAt = lastSeenAt
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
        // Absent from a server older than read state, which reads as "nothing
        // new" rather than as an error — the same rule the rest of this decoder
        // follows. Negatives are clamped: a count below zero has no meaning and
        // would draw a badge saying "-1".
        unreadCount = max(try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0, 0)
        // Absent from a server predating read state, and an unparseable value
        // reads the same way: nil, which the timeline treats as "mark nothing
        // new" rather than as everything or an error.
        lastSeenAt = try? container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        let count = try container.decodeIfPresent(Int.self, forKey: .memberCount)
        // A connection always contains at least the signed-in user.
        memberCount = max(count ?? members.count, 1)
    }

    /// True when somebody else has posted here since you last looked.
    public var hasUnread: Bool { unreadCount > 0 }

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

public extension Collection where Element == Connection {
    /// What the springboard badge should say.
    ///
    /// Muted connections are excluded, which mirrors `unseenCount` in the
    /// server's `internal/push` — the badge accompanies an alert a muted
    /// connection would not have produced, so counting it would put a number on
    /// the icon that the user cannot account for by opening anything. The rail
    /// inside the app shows muted counts, because there it sits next to the face
    /// that explains it.
    ///
    /// Lives here rather than on `AppModel` so it can be tested directly: the
    /// app's connection list is `private(set)` and only fillable from a live
    /// server, and this rule is worth more coverage than that allows.
    var totalUnreadForBadge: Int {
        filter { !$0.isMuted }.reduce(0) { $0 + $1.unreadCount }
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

    /// What the app writes to its `devices` row at the start of every session.
    ///
    /// The zone rides along so the weekly recap reaches this phone at 18:00 on
    /// Sunday where it is, not where the server is. Rewritten each session, so it
    /// follows somebody who travels.
    public static func registrationFields(
        user: String,
        pushToken: String,
        timeZone: TimeZone = .current
    ) -> [String: String] {
        ["user": user, "platform": "ios", "push_token": pushToken, "time_zone": timeZone.identifier]
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
    ///
    /// The https link rather than the server's `deep_link`, which is
    /// `peard://pair/{code}`. A custom scheme only works for somebody who
    /// already has the app: to everybody else it is "Safari cannot open the
    /// page", which is the worst possible answer to an invitation. The https
    /// form opens the app when it is installed and a page explaining how to get
    /// it when it is not — and it is built from the public host rather than the
    /// configured server, because a dev address is no use to whoever receives
    /// the message.
    public var shareMessage: String {
        let intro = isGroupInvite ? "Join my group on Pear'd!" : "Pear up with me on Pear'd!"
        guard let link = DeepLink.inviteLink(code: code)?.absoluteString else {
            return "\(intro) Code: \(code)"
        }
        return "\(intro) Code: \(code)\n\(link)"
    }
}

/// Response of `POST /api/peard/pairs/accept`.
public struct PairAcceptance: Codable, Hashable, Sendable {
    public let pair: String
    public init(pair: String) { self.pair = pair }
}

