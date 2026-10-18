import Foundation

// MARK: - Widget payloads

/// Response of `POST /api/peard/widget/token`.
public struct WidgetTokenIssue: Codable, Hashable, Sendable {
    public let id: String?
    public let token: String
    public init(id: String? = nil, token: String) {
        self.id = id
        self.token = token
    }
}

/// One row of `GET /api/peard/widget/tokens`: a signed-in device or widget, as
/// the "Signed-in devices & widgets" screen lists it (#367).
///
/// There is deliberately no secret here — the server never sends one. The id is
/// what a row is revoked by.
public struct WidgetTokenInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let created: Date?
    public let expires: Date?
    /// Not on the wire. The list route cannot know which row is the phone asking,
    /// so the client marks it by the id it was handed when it minted its own
    /// token; see `PeardAPI.widgetTokens(currentTokenID:)`.
    public var isCurrentDevice: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, created, expires
    }

    public init(
        id: String,
        label: String = "",
        created: Date? = nil,
        expires: Date? = nil,
        isCurrentDevice: Bool = false
    ) {
        self.id = id
        self.label = label
        self.created = created
        self.expires = expires
        self.isCurrentDevice = isCurrentDevice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        expires = try container.decodeIfPresent(Date.self, forKey: .expires)
        isCurrentDevice = false
    }
}

struct WidgetTokenList: Codable, Hashable, Sendable {
    let tokens: [WidgetTokenInfo]
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
        /// When the moment happened. Absent from a server predating rewinding.
        public let happenedAt: Date?
        /// Somebody picked this moment's time; see `Post.rewound`.
        public let rewound: Bool
        public let mediaURL: String?
        public let author: String?

        enum CodingKeys: String, CodingKey {
            case id, type, note, created, author, emoji, label, rewound
            case eventKind = "event_kind"
            case mediaURL = "media_url"
            case happenedAt = "happened_at"
        }

        public init(
            id: String,
            type: PostType,
            eventKind: EventKind? = nil,
            emoji: String? = nil,
            label: String? = nil,
            note: String? = nil,
            created: Date? = nil,
            happenedAt: Date? = nil,
            rewound: Bool = false,
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
            self.happenedAt = happenedAt
            self.rewound = rewound
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
            let happenedAt = try? container.decode(Date.self, forKey: .happenedAt)
            self.happenedAt = happenedAt
            var derived = false
            if let happenedAt, let created { derived = Rewind.isRewound(happenedAt, loggedAt: created) }
            rewound = (try? container.decodeIfPresent(Bool.self, forKey: .rewound)) ?? derived
            mediaURL = try container.decodeIfPresent(String.self, forKey: .mediaURL)
            author = try container.decodeIfPresent(String.self, forKey: .author)
        }

        /// When the moment happened, falling back to when it was logged.
        public var happenedOrCreated: Date? { happenedAt ?? created }


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
            if type == .note { return MomentCatalogue.replyEmoji }
            if let emoji, !emoji.isEmpty { return emoji }
            return MomentCatalogue.emoji(for: eventKind)
        }

        public var displayLabel: String {
            if type == .note { return MomentCatalogue.replyLabel }
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
    /// Moments other people have posted in this connection since you last opened
    /// it. Absent on a server that predates read state, which decodes as zero.
    public let unreadCount: Int
    /// Today's connection water against its goal, for the watch's water
    /// complication (#364). Absent on a server that predates it.
    public let water: Water?
    /// The connection's "any moment" day streak, for the watch's streak
    /// complication (#378). Absent on a server that predates it.
    public let streak: Streak?
    /// Every daily-progress metric the connection is tracking (#386) — water,
    /// steps, exercise, and the like — each with today's amount and the goal.
    /// Empty on a server that predates it; water also keeps its own `water`
    /// block for the existing water complication.
    public let metrics: [MetricSummary]

    /// One tracked metric in the feed (#386): the connection's combined amount
    /// today against the summed goal, resolved to a `MetricDefinition` for how it
    /// is drawn and a `MetricProgress` for the ring.
    public struct MetricSummary: Codable, Hashable, Sendable, Identifiable {
        public let slug: String
        public let label: String
        public let emoji: String
        public let unitRaw: String
        public let today: Int
        public let goal: Int

        public var id: String { slug }

        enum CodingKeys: String, CodingKey {
            case slug, label, emoji, today, goal
            case unitRaw = "unit"
        }

        public init(slug: String, label: String, emoji: String, unitRaw: String, today: Int, goal: Int) {
            self.slug = slug
            self.label = label
            self.emoji = emoji
            self.unitRaw = unitRaw
            self.today = today
            self.goal = goal
        }

        public var unit: MetricUnit { MetricUnit(storedValue: unitRaw) }

        /// The definition this metric is drawn by: the built-in when the slug is
        /// one, else a plain-count definition carrying the feed's label/emoji.
        public var definition: MetricDefinition {
            MetricCatalogue.resolve(
                EventKind(rawValue: slug), label: label, emoji: emoji, unit: unit, goal: goal)
        }

        /// Today's amount measured against the connection's summed goal.
        public var progress: MetricProgress {
            MetricProgress(amount: today, minimum: 0, goal: goal)
        }
    }

    /// The connection's current and best day streak (#378) — the same figure the
    /// recap shows and the "at risk" reminder (#361) is about.
    public struct Streak: Codable, Hashable, Sendable {
        public let current: Int
        public let best: Int

        public init(current: Int, best: Int) {
            self.current = current
            self.best = best
        }
    }

    /// Today's connection water and the goal it is measured against (#364), both
    /// in millilitres. The watch complication draws a ring of `today / goal`.
    public struct Water: Codable, Hashable, Sendable {
        public let todayML: Int
        public let goalML: Int

        enum CodingKeys: String, CodingKey {
            case todayML = "today_ml"
            case goalML = "goal_ml"
        }

        public init(todayML: Int, goalML: Int) {
            self.todayML = todayML
            self.goalML = goalML
        }

        /// Progress toward the goal, 0...1, built on the same `WaterProgress`
        /// the app uses so the ring means the same thing everywhere.
        public var progress: WaterProgress {
            WaterProgress(ml: todayML, minimum: 0, recommended: max(goalML, 1))
        }
    }

    public init(
        state: FeedState,
        partner: Partner? = nil,
        connection: ConnectionInfo? = nil,
        counts: Counts? = nil,
        tallies: [Tally]? = nil,
        post: FeedPost? = nil,
        moments: [AvailableMoment]? = nil,
        unreadCount: Int = 0,
        water: Water? = nil,
        streak: Streak? = nil,
        metrics: [MetricSummary] = []
    ) {
        self.state = state
        self.partner = partner
        self.connection = connection
        self.counts = counts
        self.tallies = tallies
        self.post = post
        self.moments = moments
        self.unreadCount = unreadCount
        self.water = water
        self.streak = streak
        self.metrics = metrics
    }

    /// True when the moment on the widget is one the user has not seen in the
    /// app yet.
    public var hasUnread: Bool { unreadCount > 0 }

    // Explicit rather than synthesised, because `unread` is the one field whose
    // JSON name differs from its property name. Synthesis would look for
    // "unreadCount", never find it, and — since the property is not optional —
    // fail the decode of the *entire* feed. That is the whole widget going blank
    // to add a number to it.
    enum CodingKeys: String, CodingKey {
        case state, partner, connection, counts, tallies, post, moments, water, streak, metrics
        case unreadCount = "unread"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(FeedState.self, forKey: .state)
        partner = try container.decodeIfPresent(Partner.self, forKey: .partner)
        connection = try container.decodeIfPresent(ConnectionInfo.self, forKey: .connection)
        counts = try container.decodeIfPresent(Counts.self, forKey: .counts)
        tallies = try container.decodeIfPresent([Tally].self, forKey: .tallies)
        post = try container.decodeIfPresent(FeedPost.self, forKey: .post)
        moments = try container.decodeIfPresent([AvailableMoment].self, forKey: .moments)
        // Absent on a server predating read state: nothing new, not an error.
        unreadCount = max(try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0, 0)
        // Absent (or null) on a server predating the water complication (#364).
        water = try? container.decodeIfPresent(Water.self, forKey: .water)
        // Absent (or null) on a server predating the streak complication (#378).
        streak = try? container.decodeIfPresent(Streak.self, forKey: .streak)
        // Absent on a server predating generalised metrics (#386); an empty list
        // is the safe default — water keeps its own `water` block regardless.
        metrics = (try? container.decodeIfPresent([MetricSummary].self, forKey: .metrics)) ?? []
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
    /// What this connection can log, present only when the caller asked for it
    /// (`widgetConnections(token:withMoments:)`). Nil means "not requested",
    /// which is not the same as "none" — every connection can log the built-ins.
    public let moments: [WidgetFeed.AvailableMoment]?

    enum CodingKeys: String, CodingKey {
        case id, title, moments
        case memberCount = "member_count"
        case isGroup = "is_group"
    }

    public init(
        id: String,
        title: String,
        memberCount: Int = 2,
        isGroup: Bool = false,
        moments: [WidgetFeed.AvailableMoment]? = nil
    ) {
        self.id = id
        self.title = title
        self.memberCount = memberCount
        self.isGroup = isGroup
        self.moments = moments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? PartnerLabel.fallback
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount) ?? 2
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        moments = try container.decodeIfPresent([WidgetFeed.AvailableMoment].self, forKey: .moments)
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

/// A moment a widget button just fired off, and how it went — kept in the App
/// Group container so the widget can say so.
///
/// It used to be deleted the moment the request finished. The widget's own
/// timeline builds its entry after a network fetch of its own, so by the time
/// it looked, the log had usually finished and gone: the acknowledgement almost
/// never drew, and a tap looked like it did nothing. Now the outcome stays, and
/// the widget shows it until `visibleUntil`, then schedules itself back.
public struct PendingWidgetLog: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// `queued` is a tap that could not reach the server and is waiting in
        /// the `MomentInbox` for the app to send.
        case logged, queued, failed
    }

    public let pairID: String?
    public let emoji: String
    public let label: String
    public let at: Date
    /// `nil` while the request is in flight.
    public var outcome: Outcome?
    public var finishedAt: Date?

    public init(pairID: String?, emoji: String, label: String, at: Date, outcome: Outcome? = nil, finishedAt: Date? = nil) {
        self.pairID = pairID
        self.emoji = emoji
        self.label = label
        self.at = at
        self.outcome = outcome
        self.finishedAt = finishedAt
    }

    /// An unfinished log is dropped after this long, so a widget that never
    /// heard the outcome (the extension was suspended mid-request) does not say
    /// "logging…" for an hour.
    public static let maxAge: TimeInterval = 10

    /// How long the outcome stays up once known: long enough to read at a
    /// glance, short enough that the tallies are back before anyone looks again.
    public static let outcomeDisplay: TimeInterval = 4

    public func finished(_ outcome: Outcome, at date: Date = Date()) -> PendingWidgetLog {
        var copy = self
        copy.outcome = outcome
        copy.finishedAt = date
        return copy
    }

    /// When the widget should go back to its usual content.
    public var visibleUntil: Date {
        if let finishedAt { return finishedAt.addingTimeInterval(Self.outcomeDisplay) }
        return at.addingTimeInterval(Self.maxAge)
    }

    public func isVisible(now: Date = Date()) -> Bool { now < visibleUntil }

    /// Kept for callers that only ask whether to show it at all.
    public var isFresh: Bool { isVisible() }
}

