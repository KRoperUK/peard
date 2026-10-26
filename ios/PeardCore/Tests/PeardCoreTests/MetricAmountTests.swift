import XCTest
@testable import PeardCore

/// A moment's amount is no longer water's alone (#390): a daily-progress metric
/// carries one in its own canonical unit, with its own ceiling.
final class MetricAmountTests: XCTestCase {
    private func steps() -> Moment {
        Moment(kind: "steps", emoji: "👟", label: "Steps", origin: .preset)
    }

    private func water() -> Moment {
        Moment(kind: .water, emoji: "💧", label: "Water", origin: .preset)
    }

    // MARK: QuickSend

    func testAStepMomentTakesAnAmount() {
        var send = QuickSend(moment: steps())
        XCTAssertTrue(send.takesAmount)

        send.setAmount(8000)

        XCTAssertEqual(send.amount, 8000, "a count in the thousands is not a typo")
        XCTAssertTrue(send.isHeld, "choosing an amount holds the send")
    }

    /// A beer is a moment but not a metric: it asks for no amount, and one handed
    /// in is dropped.
    func testAMomentThatIsNotAMetricTakesNoAmount() {
        let beer = MomentCatalogue.builtin.first { $0.kind == .beer }!
        var send = QuickSend(moment: beer)

        XCTAssertFalse(send.takesAmount)
        send.setAmount(330)
        XCTAssertNil(send.amount)
    }

    func testAnAmountAboveTheMetricsCeilingIsDropped() {
        var send = QuickSend(moment: steps())

        send.setAmount(MetricCatalogue.steps.maximum + 1)

        XCTAssertNil(send.amount)
    }

    /// Water's ceiling is its own, through its definition — the wire's bound moved
    /// (#390) but five litres in one go is still five litres.
    func testWaterKeepsItsOwnCeiling() {
        var send = QuickSend(moment: water())

        send.setAmount(WaterAmount.maximum)
        XCTAssertEqual(send.amount, WaterAmount.maximum)

        send.setAmount(WaterAmount.maximum + 1)
        XCTAssertNil(send.amount)
    }

    // MARK: The queue

    func testAStepAmountSurvivesTheQueue() {
        let send = PendingSend(
            pairID: "p1", authorID: "me", kind: "steps", emoji: "👟", label: "Steps", amount: 8000
        )

        XCTAssertEqual(send.amount, 8000)
        XCTAssertEqual(send.postFields["amount"], "8000", "and it is what goes to the server")
    }

    func testAWaterAmountAboveItsCeilingIsStillDroppedByTheQueue() {
        let send = PendingSend(
            pairID: "p1", authorID: "me", kind: .water, emoji: "💧", label: "Water",
            amount: WaterAmount.maximum + 1
        )

        XCTAssertNil(send.amount)
    }

    // MARK: Reading back

    /// A steps moment of 8,000 comes back with its amount: the read path
    /// allows up to the wire ceiling, not water's five litres (#437).
    func testAStepAmountSurvivesTheReadBack() throws {
        let json = Data("""
        { "id": "p1", "pair": "pair1", "author": "me", "type": "event", "event_kind": "steps", "amount": 8000 }
        """.utf8)

        XCTAssertEqual(try JSONDecoder.peard.decode(Post.self, from: json).amount, 8000)
    }

    /// …while the wire's own sanity bound still applies on the way in: the
    /// server could never have stored more, so more is corrupt, not an amount.
    func testAnAbsurdAmountIsDroppedOnRead() throws {
        let json = Data("""
        { "id": "p1", "pair": "pair1", "author": "me", "type": "event", "event_kind": "steps", "amount": 1000001 }
        """.utf8)

        XCTAssertNil(try JSONDecoder.peard.decode(Post.self, from: json).amount)
    }
}
