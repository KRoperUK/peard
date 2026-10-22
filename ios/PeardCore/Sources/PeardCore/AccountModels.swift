import Foundation

// MARK: - Account, contacts and recap payloads

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
    /// Whether contact search can surface this account to someone else — see
    /// `updateDiscoverability(discoverable:phone:)`.
    public let discoverable: Bool
    /// Only ever set via the discoverability settings route, never at signup.
    public let phone: String
    /// An address other people would recognise, hashed for contact matching in
    /// place of `email`. Empty when the account's own address is the one to
    /// match on, which is the usual case.
    public let contactEmail: String
    /// True when `email` is a Sign in with Apple private relay address —
    /// `something@privaterelay.appleid.com`. Those are generated per app, per
    /// account, so nobody can have one in their contacts and matching on it
    /// can never succeed. It is the whole reason `contactEmail` exists.
    public let emailIsRelay: Bool

    enum CodingKeys: String, CodingKey {
        case id, email, discoverable, phone
        case displayName = "display_name"
        case avatarFilename = "avatar"
        case contactEmail = "contact_email"
        case emailIsRelay = "email_is_relay"
    }

    public init(
        id: String,
        displayName: String = "",
        email: String? = nil,
        avatarFilename: String? = nil,
        discoverable: Bool = false,
        phone: String = "",
        contactEmail: String = "",
        emailIsRelay: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.avatarFilename = avatarFilename
        self.discoverable = discoverable
        self.phone = phone
        self.contactEmail = contactEmail
        self.emailIsRelay = emailIsRelay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        avatarFilename = try container.decodeIfPresent(String.self, forKey: .avatarFilename)
        discoverable = try container.decodeIfPresent(Bool.self, forKey: .discoverable) ?? false
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        contactEmail = try container.decodeIfPresent(String.self, forKey: .contactEmail) ?? ""
        // Absent on a server that predates the field, which is not the same as
        // "not a relay address" — but the address itself is right here, so the
        // client can answer the question rather than assume an answer.
        emailIsRelay = try container.decodeIfPresent(Bool.self, forKey: .emailIsRelay)
            ?? AppleRelayEmail.isRelay(email)
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

/// One result from `POST /api/peard/contacts/match` — a Pear'd account that
/// opted into discoverability and matched one of the caller's contacts.
/// Deliberately thin: just enough to show who they are and invite them,
/// never which contact field matched or the value that matched it.
public struct ContactMatch: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let avatar: String?
    /// One of the hashes this device submitted — since it is the caller's
    /// own hash, echoing it back is how the app maps an anonymous match back
    /// to "this is your contact Alex", without the server ever saying which
    /// contact field matched.
    public let hash: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatar
        case hash
    }

    public init(id: String, displayName: String, avatar: String? = nil, hash: String) {
        self.id = id
        self.displayName = displayName
        self.avatar = avatar
        self.hash = hash
    }
}

struct ContactMatchList: Codable, Hashable, Sendable {
    let matches: [ContactMatch]
}

/// Response of `POST /api/peard/contacts/settings`.
public struct DiscoverabilityStatus: Codable, Hashable, Sendable {
    public let discoverable: Bool
    public let phone: String
    /// The address matching hashes in place of the account's own, echoed back
    /// as stored — normalised, so what is shown is what will actually match.
    public let contactEmail: String
    public let emailIsRelay: Bool

    enum CodingKeys: String, CodingKey {
        case discoverable, phone
        case contactEmail = "contact_email"
        case emailIsRelay = "email_is_relay"
    }

    public init(
        discoverable: Bool,
        phone: String,
        contactEmail: String = "",
        emailIsRelay: Bool = false
    ) {
        self.discoverable = discoverable
        self.phone = phone
        self.contactEmail = contactEmail
        self.emailIsRelay = emailIsRelay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discoverable = try container.decodeIfPresent(Bool.self, forKey: .discoverable) ?? false
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        contactEmail = try container.decodeIfPresent(String.self, forKey: .contactEmail) ?? ""
        emailIsRelay = try container.decodeIfPresent(Bool.self, forKey: .emailIsRelay) ?? false
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

/// Response of `GET /api/peard/status` — which build of the server is running.
///
/// Every field is optional-with-a-fallback because this is the one call whose
/// whole job is to work when something else is wrong: a server too old to have
/// the route at all is itself the answer, and a decode failure here would hide
/// it behind a generic error.
/// Response of `GET /api/peard/recap` — the last few days, and how long the
/// connection has kept going.
///
/// Every field is tolerant of absence. A server predating this route answers
/// 404, which the caller handles; one that gains fields later must not break an
/// installed app, and one that answers with a connection nobody has logged in
/// yet is answering correctly with zeroes.
public struct MomentRecap: Codable, Hashable, Sendable {
    public struct Kind: Codable, Hashable, Sendable, Identifiable {
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

    /// The day in the window with the most moments on it.
    public struct BusiestDay: Codable, Hashable, Sendable {
        /// `yyyy-MM-dd` in the caller's own clock, which is the clock the server
        /// was asked to bucket by.
        public let date: String
        public let count: Int

        public init(date: String, count: Int) {
            self.date = date
            self.count = count
        }
    }

    public struct Streak: Codable, Hashable, Sendable {
        /// Days in a row, up to and including today or yesterday. Zero once a
        /// whole day has passed with nothing in it.
        public let current: Int
        /// The longest run within the server's horizon.
        public let best: Int

        public init(current: Int = 0, best: Int = 0) {
            self.current = current
            self.best = best
        }
    }

    /// One non-water metric's streak (#391): the connection's run and the
    /// caller's own, with the goals they were measured against.
    public struct MetricStreak: Codable, Hashable, Sendable, Identifiable {
        public let metric: String
        public let current: Int
        public let best: Int
        public let goal: Int
        public let mineGoal: Int
        public let mine: Streak

        public var id: String { metric }

        public init(
            metric: String,
            current: Int = 0,
            best: Int = 0,
            goal: Int = 0,
            mineGoal: Int = 0,
            mine: Streak = Streak()
        ) {
            self.metric = metric
            self.current = current
            self.best = best
            self.goal = goal
            self.mineGoal = mineGoal
            self.mine = mine
        }

        enum CodingKeys: String, CodingKey {
            case metric, current, best, goal, mine
            case mineGoal = "mine_goal"
        }

        /// Absent figures are zeroes rather than a decode failure: a server that
        /// gains or loses a field must not cost the row, and a connection's own
        /// metric is still drawable from its slug alone.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metric = try container.decodeIfPresent(String.self, forKey: .metric) ?? ""
            current = try container.decodeIfPresent(Int.self, forKey: .current) ?? 0
            best = try container.decodeIfPresent(Int.self, forKey: .best) ?? 0
            goal = try container.decodeIfPresent(Int.self, forKey: .goal) ?? 0
            mineGoal = try container.decodeIfPresent(Int.self, forKey: .mineGoal) ?? 0
            mine = try container.decodeIfPresent(Streak.self, forKey: .mine) ?? Streak()
        }

        /// How this metric is drawn and read: the built-in when the slug names
        /// one, else a plain-count fallback carrying the metric's own slug.
        public var definition: MetricDefinition {
            MetricCatalogue.resolve(EventKind(rawValue: metric), goal: goal)
        }

        /// Worth a row only when there is a run to speak of: live, or a best of
        /// more than a day. The same bar the moment and water streaks use.
        public var isWorthShowing: Bool { current > 0 || best > 1 }
    }

    public let total: Int
    public let mine: Int
    public let others: Int
    public let kinds: [Kind]
    public let busiest: BusiestDay?
    public let streak: Streak
    /// Days in a row the connection's combined water reached the recommended
    /// amount (#323). Nil from a server that predates it, which is not the same
    /// as a streak of zero: the screen shows nothing rather than "broken".
    public let waterStreak: Streak?
    /// Days in a row the *caller's own* water reached their own target (#353).
    /// Nil from a server that predates it, like waterStreak — the person's own
    /// streak, the one the "streak at risk" reminder is about, as distinct from
    /// the connection's combined one.
    public let waterStreakMine: Streak?
    /// Every member's stored daily water targets (#335), the caller's included.
    /// Nil from a server that predates them — not the same as nobody having set
    /// one, which is a list of members whose targets are unset.
    public let waterTargets: [MemberWaterTarget]?
    /// A streak for every other tracked metric (#391), steps and exercise
    /// included. Empty from a server that predates it and from a connection
    /// that tracks nothing besides water.
    public let metricStreaks: [MetricStreak]

    public init(
        total: Int = 0,
        mine: Int = 0,
        others: Int = 0,
        kinds: [Kind] = [],
        busiest: BusiestDay? = nil,
        streak: Streak = Streak(),
        waterStreak: Streak? = nil,
        waterStreakMine: Streak? = nil,
        waterTargets: [MemberWaterTarget]? = nil,
        metricStreaks: [MetricStreak] = []
    ) {
        self.total = total
        self.mine = mine
        self.others = others
        self.kinds = kinds
        self.busiest = busiest
        self.streak = streak
        self.waterStreak = waterStreak
        self.waterStreakMine = waterStreakMine
        self.waterTargets = waterTargets
        self.metricStreaks = metricStreaks
    }

    private enum CodingKeys: String, CodingKey {
        case total, mine, others, kinds, busiest, streak
        case waterStreak = "water_streak"
        case waterStreakMine = "water_streak_mine"
        case waterTargets = "water_targets"
        case metricStreaks = "metric_streaks"
    }

    /// One element that does not decode is dropped rather than failing the list.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        mine = try container.decodeIfPresent(Int.self, forKey: .mine) ?? 0
        others = try container.decodeIfPresent(Int.self, forKey: .others) ?? 0
        kinds = try container.decodeIfPresent([Kind].self, forKey: .kinds) ?? []
        busiest = try? container.decodeIfPresent(BusiestDay.self, forKey: .busiest)
        streak = try container.decodeIfPresent(Streak.self, forKey: .streak) ?? Streak()
        waterStreak = try? container.decodeIfPresent(Streak.self, forKey: .waterStreak)
        waterStreakMine = try? container.decodeIfPresent(Streak.self, forKey: .waterStreakMine)
        waterTargets = (try? container.decodeIfPresent([Lenient<MemberWaterTarget>].self, forKey: .waterTargets))?
            .compactMap(\.value)
        metricStreaks = (try? container.decodeIfPresent([Lenient<MetricStreak>].self, forKey: .metricStreaks))?
            .compactMap(\.value) ?? []
    }

    /// True when there is nothing to summarise, so a screen can say so rather
    /// than draw a row of zeroes.
    public var isEmpty: Bool { total == 0 && streak.current == 0 && streak.best == 0 }

    /// The moment logged most in the window, which is the headline.
    public var headline: Kind? { kinds.first }
}

public struct ServerStatus: Codable, Hashable, Sendable {
    public let commit: String
    public let builtAt: String
    public let go: String

    enum CodingKeys: String, CodingKey {
        case commit, go
        case builtAt = "built_at"
    }

    public init(commit: String = "unknown", builtAt: String = "unknown", go: String = "unknown") {
        self.commit = commit
        self.builtAt = builtAt
        self.go = go
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? "unknown"
        builtAt = try container.decodeIfPresent(String.self, forKey: .builtAt) ?? "unknown"
        go = try container.decodeIfPresent(String.self, forKey: .go) ?? "unknown"
    }
}

/// Response of `POST /api/files/token`.
public struct FileTokenIssue: Codable, Hashable, Sendable {
    public let token: String
    public init(token: String) { self.token = token }
}
