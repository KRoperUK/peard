import Foundation

/// Event counts for the four reporting windows (Requirement 12.8).
///
/// `Codable` because these are exactly the four keys
/// `GET /api/peard/tallies` returns per side, so the server's counts decode
/// straight into the type the UI already draws.
public struct TallyPeriods: Codable, Hashable, Sendable {
    public var day: Int
    public var week: Int
    public var month: Int
    public var all: Int

    public static let zero = TallyPeriods(day: 0, week: 0, month: 0, all: 0)

    public init(day: Int, week: Int, month: Int, all: Int) {
        self.day = day
        self.week = week
        self.month = month
        self.all = all
    }

    /// A missing side decodes as zero rather than failing the whole response: a
    /// connection where nobody else has logged anything has no `others` counts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(Int.self, forKey: .day) ?? 0
        week = try container.decodeIfPresent(Int.self, forKey: .week) ?? 0
        month = try container.decodeIfPresent(Int.self, forKey: .month) ?? 0
        all = try container.decodeIfPresent(Int.self, forKey: .all) ?? 0
    }

    /// Counts `event` posts against each window independently, so a week that
    /// straddles a month boundary cannot inflate the month count.
    public static func compute(
        posts: [Post],
        now: Date = Date(),
        calendar: Calendar = .peardTally
    ) -> TallyPeriods {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        var periods = TallyPeriods.zero
        for post in posts {
            let created = post.created
            periods.all += 1
            if created >= dayStart { periods.day += 1 }
            if created >= weekStart { periods.week += 1 }
            if created >= monthStart { periods.month += 1 }
        }
        return periods
    }

    /// Splits a pair's event posts into the signed-in user's and the partner's
    /// tallies (Requirement 12.9).
    public static func split(
        posts: [Post],
        signedInUserID: String,
        now: Date = Date(),
        calendar: Calendar = .peardTally
    ) -> (mine: TallyPeriods, partner: TallyPeriods) {
        let mine = posts.filter { $0.author == signedInUserID }
        let theirs = posts.filter { $0.author != signedInUserID }
        return (
            compute(posts: mine, now: now, calendar: calendar),
            compute(posts: theirs, now: now, calendar: calendar)
        )
    }
}

public extension Calendar {
    /// The user's calendar with the week pinned to Monday (Requirement 12.8).
    static var peardTally: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }
}
