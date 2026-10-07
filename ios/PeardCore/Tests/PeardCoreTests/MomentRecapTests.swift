import XCTest
@testable import PeardCore

/// The recap payload, and the request that asks for it.
///
/// Decoding is tolerant on purpose: this route did not exist until now, so an
/// installed app will meet servers without it and servers that later grow
/// fields it has never heard of. Neither may break a screen.
final class MomentRecapTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: The request

    /// The window boundary and the UTC offset both go up, for the same reason
    /// the tallies route takes its windows from the caller: a streak is nothing
    /// but a sequence of days, and the server has no business guessing which
    /// days a device means.
    func testTheRequestCarriesTheWindowAndTheClock() async throws {
        StubURLProtocol.respond(json: #"{"total":0}"#)

        _ = try await client.recap(pairID: "pair1")

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/api/peard/recap")
        XCTAssertEqual(items["pair"], "pair1")
        XCTAssertFalse((items["from"] ?? "").isEmpty)
        XCTAssertNotNil(Int(items["tz"] ?? ""), "the offset has to be a number of minutes")
    }

    /// Seven days means today and the six before it, not today minus seven.
    func testTheWindowStartsSixDaysBeforeToday() async throws {
        StubURLProtocol.respond(json: #"{"total":0}"#)
        let now = Date()

        _ = try await client.recap(pairID: "pair1", days: 7, now: now)

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        let from = try XCTUnwrap(components.queryItems?.first { $0.name == "from" }?.value)
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: from))

        let calendar = Calendar.peardTally
        let expected = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        XCTAssertEqual(parsed, expected)
    }

    // MARK: Water streak (#323)

    /// The connection's own recommended amount goes up, because it lives on the
    /// device and the server cannot know a custom one.
    func testTheRequestCarriesTheWaterTarget() async throws {
        StubURLProtocol.respond(json: #"{"total":0}"#)

        _ = try await client.recap(pairID: "pair1", waterTarget: 2500)

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.queryItems?.first { $0.name == "water_target" }?.value, "2500")
    }

    /// Without one, nothing is sent and the server uses the built-in amount.
    func testTheRequestOmitsTheWaterTargetWhenThereIsNone() async throws {
        StubURLProtocol.respond(json: #"{"total":0}"#)

        _ = try await client.recap(pairID: "pair1")

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        XCTAssertNil(components.queryItems?.first { $0.name == "water_target" })
    }

    func testAWaterStreakDecodes() throws {
        let json = #"{"total":3,"streak":{"current":5,"best":9},"water_streak":{"current":4,"best":6}}"#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertEqual(recap.waterStreak, MomentRecap.Streak(current: 4, best: 6))
        XCTAssertEqual(recap.streak.current, 5, "the moment streak is its own number")
    }

    /// A server that predates the field says nothing, which is not a streak of
    /// zero.
    func testAnOldServerHasNoWaterStreak() throws {
        let json = #"{"total":3,"streak":{"current":5,"best":9}}"#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertNil(recap.waterStreak)
        XCTAssertEqual(recap.streak.current, 5)
    }

    /// A malformed field costs the water row, not the recap.
    func testAMalformedWaterStreakIsIgnored() throws {
        let json = #"{"total":3,"streak":{"current":2,"best":2},"water_streak":"lots"}"#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertNil(recap.waterStreak)
        XCTAssertEqual(recap.total, 3)
    }

    // MARK: Decoding

    func testAFullRecapDecodes() throws {
        let json = #"""
        {"pair":"p1","total":12,"mine":10,"others":2,
         "kinds":[{"kind":"coffee","emoji":"☕","label":"Coffee","count":6},
                  {"kind":"beer","emoji":"🍺","label":"Beer","count":5}],
         "busiest":{"date":"2026-08-01","count":7},
         "streak":{"current":5,"best":9}}
        """#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertEqual(recap.total, 12)
        XCTAssertEqual(recap.mine, 10)
        XCTAssertEqual(recap.others, 2)
        XCTAssertEqual(recap.kinds.count, 2)
        XCTAssertEqual(recap.headline?.kind, .coffee)
        XCTAssertEqual(recap.busiest?.date, "2026-08-01")
        XCTAssertEqual(recap.busiest?.count, 7)
        XCTAssertEqual(recap.streak.current, 5)
        XCTAssertEqual(recap.streak.best, 9)
        XCTAssertFalse(recap.isEmpty)
    }

    /// A connection nobody has logged in yet. The server omits `busiest`
    /// entirely rather than sending a day with nothing on it.
    func testAnEmptyRecapDecodesToZeroes() throws {
        let recap = try JSONDecoder.peard.decode(
            MomentRecap.self, from: Data(#"{"pair":"p1","total":0,"mine":0,"others":0,"kinds":[]}"#.utf8)
        )

        XCTAssertTrue(recap.isEmpty)
        XCTAssertNil(recap.busiest)
        XCTAssertEqual(recap.streak.current, 0)
        XCTAssertEqual(recap.streak.best, 0)
        XCTAssertNil(recap.headline)
    }

    /// Every field absent. Not a shape the server sends, but the one that
    /// decides whether a future server can add or drop a field without
    /// breaking an app somebody already has.
    func testAnEmptyObjectStillDecodes() throws {
        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data("{}".utf8))

        XCTAssertTrue(recap.isEmpty)
        XCTAssertTrue(recap.kinds.isEmpty)
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = #"""
        {"total":3,"mine":3,"others":0,"kinds":[],"streak":{"current":1,"best":1},
         "something_new":{"nested":true}}
        """#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertEqual(recap.total, 3)
    }

    /// A moment kind this client has never heard of still counts and still
    /// draws: `EventKind` is an open enum for exactly this, and a connection
    /// can invent one at any time.
    func testACustomKindDecodes() throws {
        let json = #"""
        {"total":2,"mine":2,"others":0,
         "kinds":[{"kind":"dog_walk","emoji":"🐕","label":"Dog walk","count":2}],
         "streak":{"current":1,"best":1}}
        """#

        let recap = try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))

        XCTAssertEqual(recap.headline?.kind.rawValue, "dog_walk")
        XCTAssertEqual(recap.headline?.emoji, "🐕")
        XCTAssertEqual(recap.headline?.count, 2)
    }

    // MARK: isEmpty

    /// A broken streak with nothing logged this week is still worth drawing —
    /// "best was 9" is the encouraging half of that sentence.
    func testARecapWithOnlyAPastStreakIsNotEmpty() throws {
        let recap = try JSONDecoder.peard.decode(
            MomentRecap.self, from: Data(#"{"total":0,"streak":{"current":0,"best":9}}"#.utf8)
        )

        XCTAssertFalse(recap.isEmpty)
    }
}
