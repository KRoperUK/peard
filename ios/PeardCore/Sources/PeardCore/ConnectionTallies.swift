import Foundation

/// Response of `GET /api/peard/tallies?pair=…`.
///
/// Replaces counting on the device. The app used to fetch every `event` post of a
/// connection — `perPage=500`, sorted `-created` — and run `TallyPeriods.split`
/// over the result, on every tap. That undercounted silently once a connection
/// passed 500 event posts, and moved up to 500 records to derive eight integers.
///
/// `TallyPeriods.split` is kept: it is what computes the tallies for locally
/// queued sends that have not reached the server yet, and it is the fallback when
/// a server predating this route returns 404.
public struct ConnectionTallies: Codable, Hashable, Sendable {
    /// One moment kind's counts, both sides.
    public struct Kind: Codable, Hashable, Sendable, Identifiable {
        public let kind: EventKind
        public let emoji: String
        public let label: String
        public let mine: TallyPeriods
        public let others: TallyPeriods

        public var id: String { kind.rawValue }

        /// Everybody's count, all time.
        public var total: Int { mine.all + others.all }

        enum CodingKeys: String, CodingKey {
            case kind, emoji, label, mine, others
        }

        public init(
            kind: EventKind,
            emoji: String,
            label: String,
            mine: TallyPeriods = .zero,
            others: TallyPeriods = .zero
        ) {
            self.kind = kind
            self.emoji = emoji
            self.label = label
            self.mine = mine
            self.others = others
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(EventKind.self, forKey: .kind)
            emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? MomentCatalogue.fallbackEmoji
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? MomentSlug.humanised(kind)
            mine = try container.decodeIfPresent(TallyPeriods.self, forKey: .mine) ?? .zero
            others = try container.decodeIfPresent(TallyPeriods.self, forKey: .others) ?? .zero
        }
    }

    public let pair: String
    public let mine: TallyPeriods
    public let others: TallyPeriods
    public let kinds: [Kind]

    public static let zero = ConnectionTallies(pair: "", mine: .zero, others: .zero, kinds: [])

    public init(pair: String, mine: TallyPeriods, others: TallyPeriods, kinds: [Kind]) {
        self.pair = pair
        self.mine = mine
        self.others = others
        self.kinds = kinds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pair = try container.decodeIfPresent(String.self, forKey: .pair) ?? ""
        mine = try container.decodeIfPresent(TallyPeriods.self, forKey: .mine) ?? .zero
        others = try container.decodeIfPresent(TallyPeriods.self, forKey: .others) ?? .zero
        kinds = try container.decodeIfPresent([Kind].self, forKey: .kinds) ?? []
    }

    /// The kinds that anybody has logged, most logged first, then alphabetically
    /// so the order is stable between two equally-used moments.
    public var rankedKinds: [Kind] {
        kinds.sorted {
            $0.total == $1.total ? $0.kind.rawValue < $1.kind.rawValue : $0.total > $1.total
        }
    }

    /// Adds locally queued sends that the server has not seen yet, so a moment
    /// logged with no signal still moves the number the moment it is tapped.
    ///
    /// Only `mine` moves: a queued send is by definition the user's own.
    ///
    /// Sends are matched on `pair`, so the receiver must carry the connection's id
    /// — `ConnectionTallies.zero` does not, and merging into it would silently
    /// discard everything.
    public func adding(pending: [PendingSend], now: Date = Date(), calendar: Calendar = .peardTally) -> ConnectionTallies {
        let relevant = pending.filter { $0.pairID == pair }
        guard !relevant.isEmpty else { return self }

        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        func bump(_ periods: TallyPeriods, at date: Date) -> TallyPeriods {
            var next = periods
            next.all += 1
            if date >= dayStart { next.day += 1 }
            if date >= weekStart { next.week += 1 }
            if date >= monthStart { next.month += 1 }
            return next
        }

        var totals = mine
        var byKind = Dictionary(uniqueKeysWithValues: kinds.map { ($0.kind.rawValue, $0) })

        for send in relevant {
            totals = bump(totals, at: send.queuedAt)
            let key = send.kind.rawValue
            if let existing = byKind[key] {
                byKind[key] = Kind(
                    kind: existing.kind,
                    emoji: existing.emoji,
                    label: existing.label,
                    mine: bump(existing.mine, at: send.queuedAt),
                    others: existing.others
                )
            } else {
                byKind[key] = Kind(
                    kind: send.kind,
                    emoji: send.emoji,
                    label: send.label,
                    mine: bump(.zero, at: send.queuedAt),
                    others: .zero
                )
            }
        }

        // Preserve the server's order, then append kinds only the queue knows
        // about, so the list does not jump around as sends drain.
        var ordered = kinds.compactMap { byKind[$0.kind.rawValue] }
        let known = Set(kinds.map(\.kind.rawValue))
        for send in relevant where !known.contains(send.kind.rawValue) {
            if let extra = byKind[send.kind.rawValue], !ordered.contains(where: { $0.kind == extra.kind }) {
                ordered.append(extra)
            }
        }

        return ConnectionTallies(pair: pair, mine: totals, others: others, kinds: ordered)
    }
}
