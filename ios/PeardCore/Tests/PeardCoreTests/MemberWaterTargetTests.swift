import XCTest
@testable import PeardCore

/// Per-person water targets shared across a connection (#335): how the recap
/// carries them, how a client writes its own, and that an older server — or a
/// garbled one — never takes the screen down.
final class MemberWaterTargetTests: XCTestCase {
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

    private func decode(_ json: String) throws -> MomentRecap {
        try JSONDecoder.peard.decode(MomentRecap.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testTheRecapCarriesEveryMembersTarget() throws {
        let recap = try decode(#"""
        {"total":1,"water_targets":[
          {"user":"me","minimum":1200,"recommended":2500},
          {"user":"ari","minimum":0,"recommended":2000}]}
        """#)

        XCTAssertEqual(recap.waterTargets?.count, 2)
        XCTAssertEqual(recap.waterTarget(forUser: "me"), MemberWaterTarget(user: "me", minimum: 1200, recommended: 2500))
        XCTAssertEqual(recap.otherWaterTargets(excluding: "me").map(\.user), ["ari"])
    }

    /// An older server sends no field: nil, which is not "nobody set one".
    func testAnOldServerHasNoTargetsAtAll() throws {
        let recap = try decode(#"{"total":3,"mine":3}"#)

        XCTAssertNil(recap.waterTargets)
        XCTAssertNil(recap.waterTarget(forUser: "me"))
        XCTAssertEqual(recap.otherWaterTargets(excluding: "me"), [])
    }

    /// Zero is the server's "none stored", and is not a target to draw.
    func testAMemberWhoSetNothingHasNoTarget() throws {
        let recap = try decode(#"{"water_targets":[{"user":"me","minimum":0,"recommended":0}]}"#)

        XCTAssertEqual(recap.waterTargets?.count, 1)
        XCTAssertNil(recap.waterTarget(forUser: "me"))
        XCTAssertFalse(try XCTUnwrap(recap.waterTargets?.first).isSet)
    }

    func testMissingNumbersReadAsUnset() throws {
        let recap = try decode(#"{"water_targets":[{"user":"me"}]}"#)

        XCTAssertEqual(recap.waterTargets, [MemberWaterTarget(user: "me")])
    }

    /// One malformed entry is dropped; the rest survive and nothing throws.
    func testAMalformedEntryIsDroppedNotFatal() throws {
        let recap = try decode(#"""
        {"total":2,"water_targets":[{"minimum":5},{"user":"ari","minimum":"lots","recommended":2000},
        {"user":"me","minimum":900,"recommended":1800}]}
        """#)

        XCTAssertEqual(recap.waterTargets?.map(\.user), ["me"])
        XCTAssertEqual(recap.total, 2)
    }

    func testAGarbledFieldReadsAsAnOldServer() throws {
        let recap = try decode(#"{"total":2,"water_targets":"nope"}"#)

        XCTAssertNil(recap.waterTargets)
        XCTAssertEqual(recap.total, 2)
    }

    func testNegativeNumbersAreHeldAtZero() throws {
        let recap = try decode(#"{"water_targets":[{"user":"me","minimum":-5,"recommended":-9}]}"#)

        XCTAssertEqual(recap.waterTargets, [MemberWaterTarget(user: "me")])
    }

    // MARK: Writing

    func testSettingATargetPostsTheCallersNumbersAsJSONIntegers() async throws {
        StubURLProtocol.respond(json: #"{"ok":true}"#)

        try await client.setWaterTarget(pairID: "pair1", minimum: 1200, recommended: 2500)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/peard/water/target")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["pair"] as? String, "pair1")
        XCTAssertEqual(sent["minimum"] as? Int, 1200, "the server binds an integer; a quoted number is a 400")
        XCTAssertEqual(sent["recommended"] as? Int, 2500)
        XCTAssertNil(sent["user"], "the server takes the user from the session; there is no naming somebody else")
    }

    // MARK: Taking the server's copy

    func testSetTargetsHoldsTheInvariantsWhateverTheOrder() {
        var config = WaterConfig(minimum: 1500, recommended: 2000)

        config.setTargets(minimum: 400, recommended: 900)
        XCTAssertEqual(config.minimum, 400)
        XCTAssertEqual(config.recommended, 900)

        config.setTargets(minimum: 3000, recommended: 2500)
        XCTAssertEqual(config.minimum, 2500, "a minimum above the goal is held at the goal")
        XCTAssertEqual(config.recommended, 2500)

        config.setTargets(minimum: 0, recommended: 99_999)
        XCTAssertEqual(config.recommended, WaterAmount.maximum)
        XCTAssertEqual(config.minimum, WaterConfig.step)
    }

    func testStandardTargetsAreRecognised() {
        XCTAssertTrue(WaterConfig.standard.hasStandardTargets)
        var config = WaterConfig.standard
        config.setRecommended(2500)
        XCTAssertFalse(config.hasStandardTargets)
    }

    func testOnlyTheOwnTodayIsMeasuredAgainstTheOwnTarget() {
        let mine = TallyPeriods(day: 1, week: 1, month: 1, all: 1, dayAmount: 500)
        let theirs = TallyPeriods(day: 1, week: 1, month: 1, all: 1, dayAmount: 900)
        let tallies = ConnectionTallies(
            pair: "p", mine: .zero, others: .zero,
            kinds: [.init(kind: .water, emoji: "💧", label: "Water", mine: mine, others: theirs)]
        )

        XCTAssertEqual(tallies.waterToday, 1400)
        XCTAssertEqual(tallies.waterTodayMine, 500)
    }
}
