import XCTest
@testable import PeardCore

/// Requirement 12.8 — day / week-from-Monday / month / all-time counts.
final class TallyPeriodsTests: XCTestCase {
    /// Fixed UTC Gregorian calendar with the week starting on Monday.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ string: String) -> Date {
        PeardDate.parse(string)!
    }

    private func post(_ created: String, author: String = "me") -> Post {
        Post(
            id: UUID().uuidString, pair: "pair1", author: author, type: .event,
            eventKind: .beer, created: date(created)
        )
    }

    func testMondayIsTheStartOfTheWeek() {
        // 2026-07-28 is a Tuesday; the week starts Monday 2026-07-27.
        let now = date("2026-07-28 12:00:00.000Z")
        let posts = [
            post("2026-07-28 08:00:00.000Z"), // today
            post("2026-07-27 23:59:59.999Z"), // Monday, this week
            post("2026-07-26 23:59:59.999Z"), // Sunday, previous week
        ]

        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.day, 1)
        XCTAssertEqual(periods.week, 2)
        XCTAssertEqual(periods.month, 3)
        XCTAssertEqual(periods.all, 3)
    }

    func testSundayCountsAsTheEndOfTheWeekNotTheStart() {
        // 2026-08-02 is a Sunday; its week still starts Monday 2026-07-27.
        let now = date("2026-08-02 20:00:00.000Z")
        let posts = [
            post("2026-08-02 09:00:00.000Z"), // today (Sunday)
            post("2026-07-27 09:00:00.000Z"), // Monday of the same week
            post("2026-07-26 09:00:00.000Z"), // previous Sunday
        ]

        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.day, 1)
        XCTAssertEqual(periods.week, 2)
        XCTAssertEqual(periods.month, 1, "only the August post is in the current month")
        XCTAssertEqual(periods.all, 3)
    }

    func testWeekStraddlingAMonthBoundaryDoesNotInflateTheMonth() {
        // 2026-07-01 is a Wednesday; its week starts Monday 2026-06-29.
        let now = date("2026-07-01 12:00:00.000Z")
        let posts = [
            post("2026-07-01 08:00:00.000Z"), // today, this month
            post("2026-06-30 08:00:00.000Z"), // this week, previous month
            post("2026-06-29 08:00:00.000Z"), // this week, previous month
            post("2026-06-28 08:00:00.000Z"), // previous week and month
        ]

        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.day, 1)
        XCTAssertEqual(periods.week, 3)
        XCTAssertEqual(periods.month, 1)
        XCTAssertEqual(periods.all, 4)
    }

    func testMidnightBoundaryIsInclusive() {
        let now = date("2026-07-28 12:00:00.000Z")
        let posts = [
            post("2026-07-28 00:00:00.000Z"), // exactly midnight today
            post("2026-07-27 23:59:59.999Z"), // one millisecond earlier
        ]

        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.day, 1)
        XCTAssertEqual(periods.week, 2)
    }

    func testMonthStartBoundaryIsInclusive() {
        let now = date("2026-07-15 12:00:00.000Z")
        let posts = [
            post("2026-07-01 00:00:00.000Z"),
            post("2026-06-30 23:59:59.999Z"),
        ]

        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.month, 1)
        XCTAssertEqual(periods.all, 2)
    }

    func testEmptyInputIsAllZero() {
        let periods = TallyPeriods.compute(posts: [], now: date("2026-07-28 12:00:00.000Z"), calendar: calendar)
        XCTAssertEqual(periods, .zero)
    }

    func testSplitSeparatesMineFromPartners() {
        let now = date("2026-07-28 12:00:00.000Z")
        let posts = [
            post("2026-07-28 08:00:00.000Z", author: "me"),
            post("2026-07-28 09:00:00.000Z", author: "them"),
            post("2026-07-26 09:00:00.000Z", author: "them"),
        ]

        let (mine, partner) = TallyPeriods.split(
            posts: posts, signedInUserID: "me", now: now, calendar: calendar
        )

        XCTAssertEqual(mine, TallyPeriods(day: 1, week: 1, month: 1, all: 1))
        XCTAssertEqual(partner, TallyPeriods(day: 1, week: 1, month: 2, all: 2))
    }

    func testDefaultCalendarStartsWeekOnMonday() {
        XCTAssertEqual(Calendar.peardTally.firstWeekday, 2)
    }
}
