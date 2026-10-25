import XCTest
@testable import Peard
import PeardCore

/// The history screen's small contracts: who can be filtered on and in what
/// order, and how days and times read (#448).
///
/// Written as the screen's formatter and ordering work moved out of the
/// render path — the comparator became a stable partition, the per-row
/// newness computation was hoisted out of the row loop, and the date
/// formatters are built once — so the behaviour they pin must not change.
@MainActor
final class HistoryFormattingTests: XCTestCase {
    private let serverURL = URL(string: "http://127.0.0.1:8090")!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func model(connection: Connection? = nil) -> HistoryModel {
        HistoryModel(
            api: APIClient(baseURL: serverURL),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: connection,
            calendar: calendar
        )
    }

    private func member(_ user: String) -> Connection.Member {
        Connection.Member(user: user, name: user, role: .member, isYou: user == "me")
    }

    /// "Just mine" is the commonest filter question, so you come first; the
    /// rest keep the connection's own order rather than whatever a sort with
    /// an invalid comparator happens to produce.
    func testFilterableMembersPutsYouFirstKeepingTheRestStable() {
        let connection = Connection(pair: "pair1", members: [member("ari"), member("me"), member("zed")])

        XCTAssertEqual(
            model(connection: connection).filterableMembers.map(\.user),
            ["me", "ari", "zed"]
        )
    }

    /// Not being in the list cannot reorder it.
    func testFilterableMembersWithoutYouKeepsOrder() {
        let connection = Connection(pair: "pair1", members: [member("ari"), member("zed")])

        XCTAssertEqual(
            model(connection: connection).filterableMembers.map(\.user),
            ["ari", "zed"]
        )
    }

    func testHeadingNamesTodayYesterdayAndTheUndated() {
        let subject = model()
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!

        XCTAssertEqual(subject.heading(for: HistoryModel.Day(date: now, posts: [])), "Today")
        XCTAssertEqual(subject.heading(for: HistoryModel.Day(date: yesterday, posts: [])), "Yesterday")
        XCTAssertEqual(subject.heading(for: HistoryModel.Day(date: .distantPast, posts: [])), "Undated")
    }

    /// An old day carries its year; a day from this year reads without one.
    func testHeadingDropsTheYearForTheCurrentOne() {
        let subject = model()
        let march2020 = calendar.date(from: DateComponents(year: 2020, month: 3, day: 12))!

        let old = subject.heading(for: HistoryModel.Day(date: march2020, posts: []))
        XCTAssertTrue(old.contains("2020"), "an old day carries its year: \(old)")
        XCTAssertTrue(old.contains("March"), "and names its month: \(old)")

        let now = Date()
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!
        let heading = subject.heading(for: HistoryModel.Day(date: recent, posts: []))
        if calendar.component(.year, from: recent) == calendar.component(.year, from: now) {
            XCTAssertFalse(heading.contains(String(calendar.component(.year, from: now))),
                           "this year's dates read without one: \(heading)")
        } else {
            // Only around New Year: ten days back is last year, which carries it.
            XCTAssertTrue(heading.contains(String(calendar.component(.year, from: recent))))
        }
    }

    /// The row's time keeps its minutes through the caching: here five past
    /// two in the afternoon, whatever the hour's local shape.
    func testTimeKeepsHoursAndMinutes() {
        let subject = model()
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 14
        components.minute = 5
        let post = Post(
            id: "p1", pair: "pair1", author: "ari", type: .event, eventKind: .beer,
            created: calendar.date(from: components)!
        )

        let time = subject.time(for: post)

        XCTAssertFalse(time.isEmpty)
        XCTAssertTrue(time.contains("05"), "the minutes survive: \(time)")
    }

    func testTimeIsEmptyWithoutATimestamp() {
        let subject = model()
        let post = Post(
            id: "p1", pair: "pair1", author: "ari", type: .event, eventKind: .beer,
            created: .distantPast
        )

        XCTAssertEqual(subject.time(for: post), "")
    }
}
