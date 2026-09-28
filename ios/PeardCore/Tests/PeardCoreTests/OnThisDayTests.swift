import XCTest
@testable import PeardCore

/// "A year ago today" (issue #12).
final class OnThisDayTests: XCTestCase {
    private var london: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        london.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testTheWindowIsThisDayLastYearInLocalTime() throws {
        let window = try XCTUnwrap(OnThisDay.window(for: date(2026, 9, 28, 23), calendar: london))
        XCTAssertEqual(window.start, date(2025, 9, 28, 0))
        XCTAssertEqual(window.end, date(2025, 9, 29, 0))
    }

    /// A leap day, a year on, has no twin; it gets the 28th rather than nothing
    /// — or, worse, the 1st of March, which is a different day.
    func testALeapDayLooksAtTheTwentyEighth() throws {
        let window = try XCTUnwrap(OnThisDay.window(for: date(2028, 2, 29), calendar: london))
        XCTAssertEqual(window.start, date(2027, 2, 28, 0))
        XCTAssertEqual(window.end, date(2027, 3, 1, 0))
    }

    func testTheClauseAsksForHappenedAtInsideTheWindow() throws {
        let window = try XCTUnwrap(OnThisDay.window(for: date(2026, 9, 28), calendar: london))
        let clause = OnThisDay.clause(for: window)
        XCTAssertTrue(clause.hasPrefix("happened_at >= \"2025-09-27 23:00:00.000Z\""), clause)
        XCTAssertTrue(clause.hasSuffix("happened_at < \"2025-09-28 23:00:00.000Z\""), clause)
    }
}
