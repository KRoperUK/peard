import XCTest
@testable import PeardCore

/// Water is an ordinary moment that carries an amount (#320). The amount has to
/// ride the whole pipeline — the wire, the offline queue, the day's total — so
/// that a glass logged in a basement with no signal still arrives with its size.
final class WaterAmountTests: XCTestCase {
    private let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func send(
        id: String = "w1",
        kind: EventKind = .water,
        amount: Int? = 330,
        queuedAt: Date? = nil,
        postType: PostType = .event
    ) -> PendingSend {
        PendingSend(
            id: id,
            pairID: "pair1",
            authorID: "me",
            kind: kind,
            emoji: kind == .water ? "💧" : "🍺",
            label: kind == .water ? "Water" : "Beer",
            queuedAt: queuedAt ?? sampleDate,
            postType: postType,
            amount: amount
        )
    }

    // MARK: The amount itself

    func testPresetsAreAGlassAndABottle() {
        XCTAssertEqual(WaterAmount.presets.map(\.ml), [330, 500])
        XCTAssertEqual(WaterAmount.glass.label, "330 ml (glass)")
        XCTAssertEqual(WaterAmount.bottle.label, "500 ml (bottle)")
    }

    func testOnlyASensibleSizeIsAnAmount() {
        XCTAssertEqual(WaterAmount.normalised(330), 330)
        XCTAssertEqual(WaterAmount.normalised(WaterAmount.maximum), WaterAmount.maximum)
        XCTAssertNil(WaterAmount.normalised(nil))
        XCTAssertNil(WaterAmount.normalised(0), "the server's 0 means none")
        XCTAssertNil(WaterAmount.normalised(-5))
        XCTAssertNil(WaterAmount.normalised(WaterAmount.maximum + 1))
    }

    func testACustomSizeIsWholeDigitsInRange() {
        XCTAssertEqual(WaterAmount.parse("250"), 250)
        XCTAssertEqual(WaterAmount.parse("  750 "), 750)
        for bad in ["", "abc", "2.5", "-3", "0", "330ml", "5001", "٣٣٠"] {
            XCTAssertNil(WaterAmount.parse(bad), "\"\(bad)\" is not a size")
        }
    }

    func testATotalReadsInGroupedMillilitres() {
        let en = Locale(identifier: "en_GB")
        XCTAssertEqual(WaterAmount.label(330, locale: en), "330 ml")
        XCTAssertEqual(WaterAmount.todayLabel(1330, locale: en), "1,330 ml today")
    }

    // MARK: Post

    func testPostRoundTripsItsAmount() throws {
        let post = Post(
            id: "p1", pair: "pair1", author: "me", type: .event,
            eventKind: .water, created: sampleDate, amount: 500
        )
        let data = try JSONEncoder.peard.encode(post)
        let decoded = try JSONDecoder.peard.decode(Post.self, from: data)

        XCTAssertEqual(decoded, post)
        XCTAssertEqual(decoded.amount, 500)
    }

    func testPostWithoutAnAmountHasNone() throws {
        let json = Data("""
        { "id": "p1", "pair": "pair1", "author": "me", "type": "event", "event_kind": "beer" }
        """.utf8)
        XCTAssertNil(try JSONDecoder.peard.decode(Post.self, from: json).amount)
    }

    /// PocketBase stores an unset number as 0, so every beer comes back with
    /// `"amount": 0`. That is no amount, not an amount of nothing.
    func testServerZeroDecodesAsNoAmount() throws {
        let json = Data("""
        { "id": "p1", "pair": "pair1", "author": "me", "type": "event", "event_kind": "beer", "amount": 0 }
        """.utf8)
        XCTAssertNil(try JSONDecoder.peard.decode(Post.self, from: json).amount)
    }

    func testPostDecodesAServerAmount() throws {
        let json = Data("""
        { "id": "p1", "pair": "pair1", "author": "me", "type": "event", "event_kind": "water", "amount": 330 }
        """.utf8)
        XCTAssertEqual(try JSONDecoder.peard.decode(Post.self, from: json).amount, 330)
    }

    // MARK: PendingSend — the wire

    func testAWaterSendPutsItsAmountOnTheWire() {
        XCTAssertEqual(send(amount: 330).postFields["amount"], "330")
    }

    func testASendWithoutAnAmountSendsNone() {
        XCTAssertNil(send(kind: .beer, amount: nil).postFields["amount"])
    }

    func testAnAmountOnAPhotoIsNotSent() {
        XCTAssertNil(send(amount: 330, postType: .photo).postFields["amount"])
    }

    func testTheOptimisticPostCarriesTheAmount() {
        XCTAssertEqual(send(amount: 500).optimisticPost.amount, 500)
        XCTAssertNil(send(kind: .beer, amount: nil).optimisticPost.amount)
    }

    func testEditingAQueuedSendKeepsItsAmountWhileItIsStillWater() {
        let edited = send(amount: 500).edited(note: "after a run", kind: .water, emoji: "💧", label: "Water")
        XCTAssertEqual(edited.amount, 500)
    }

    func testEditingAQueuedSendIntoAnotherMomentDropsTheAmount() {
        let edited = send(amount: 500).edited(note: "", kind: .beer, emoji: "🍺", label: "Beer")
        XCTAssertNil(edited.amount, "millilitres of water on a beer would be nonsense")
    }

    // MARK: PendingSend — the queue

    func testAmountSurvivesTheQueueFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-water-queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilePendingSendStore(url: url)

        store.savePendingSends([send(amount: 330)])
        let loaded = store.loadPendingSends()

        XCTAssertEqual(loaded.first?.amount, 330)
        XCTAssertEqual(loaded.first?.postFields["amount"], "330", "still goes on the wire after a relaunch")
    }

    func testAQueueFileFromBeforeAmountsStillLoads() throws {
        let encoded = try JSONEncoder.peard.encode([send(id: "old", amount: 330)])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        objects[0].removeValue(forKey: "amount")
        let legacy = try JSONSerialization.data(withJSONObject: objects)

        let loaded = try JSONDecoder.peard.decode([PendingSend].self, from: legacy)

        XCTAssertEqual(loaded.map(\.id), ["old"])
        XCTAssertNil(loaded[0].amount)
        XCTAssertNil(loaded[0].postFields["amount"])
    }

    func testAQueueFileFromWellBeforeAmountsAndPhotosStillLoads() throws {
        let encoded = try JSONEncoder.peard.encode([send(id: "older", amount: 330)])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for key in ["amount", "post_type", "has_photo", "happened_at", "reply_to"] { objects[0].removeValue(forKey: key) }
        let legacy = try JSONSerialization.data(withJSONObject: objects)

        let loaded = try JSONDecoder.peard.decode([PendingSend].self, from: legacy)

        XCTAssertEqual(loaded.first?.id, "older")
        XCTAssertNil(loaded.first?.amount)
    }

    func testRetryingAFailedSendDoesNotLoseItsAmount() {
        let failed = send(amount: 500).failed(with: "offline")
        XCTAssertEqual(failed.amount, 500)
        XCTAssertEqual(failed.revived.amount, 500)
    }

    // MARK: The day's total

    private func tallies(water: ConnectionTallies.Kind? = nil) -> ConnectionTallies {
        ConnectionTallies(pair: "pair1", mine: .zero, others: .zero, kinds: water.map { [$0] } ?? [])
    }

    func testTheServerSendsTodaysMillilitresPerSide() throws {
        let json = """
        { "pair": "pair1",
          "kinds": [ { "kind": "water", "emoji": "💧", "label": "Water",
            "mine":   { "day": 2, "week": 2, "month": 2, "all": 2, "day_amount": 830 },
            "others": { "day": 1, "week": 1, "month": 1, "all": 1, "day_amount": 250 } } ] }
        """
        let decoded = try JSONDecoder.peard.decode(ConnectionTallies.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.kinds.first?.mine.dayAmount, 830)
        XCTAssertEqual(decoded.kinds.first?.others.dayAmount, 250)
        XCTAssertEqual(decoded.waterToday, 1080)
    }

    func testAServerWithoutAmountsTotalsZero() throws {
        let json = """
        { "pair": "pair1", "kinds": [ { "kind": "water", "emoji": "💧", "label": "Water",
            "mine": { "day": 2, "week": 2, "month": 2, "all": 2 } } ] }
        """
        let decoded = try JSONDecoder.peard.decode(ConnectionTallies.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.waterToday, 0)
    }

    func testAPendingWaterSendCountsInTodaysTotal() {
        let now = PeardDate.parse("2026-10-07 12:00:00.000Z")!
        let server = ConnectionTallies.Kind(
            kind: .water, emoji: "💧", label: "Water",
            mine: TallyPeriods(day: 1, week: 1, month: 1, all: 1, dayAmount: 330)
        )
        let merged = tallies(water: server).adding(
            pending: [send(amount: 500, queuedAt: now.addingTimeInterval(-60))],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.waterToday, 830)
        XCTAssertEqual(merged.kinds.first?.mine.day, 2)
    }

    func testAPendingWaterSendCountsWhenTheServerHasNeverSeenWater() {
        let now = PeardDate.parse("2026-10-07 12:00:00.000Z")!
        let merged = tallies().adding(
            pending: [send(id: "a", amount: 330, queuedAt: now), send(id: "b", amount: 500, queuedAt: now)],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.waterToday, 830)
    }

    func testYesterdaysPendingWaterIsNotInTodaysTotal() {
        let now = PeardDate.parse("2026-10-07 12:00:00.000Z")!
        let merged = tallies().adding(
            pending: [send(amount: 330, queuedAt: now.addingTimeInterval(-86_400 * 2))],
            now: now, calendar: calendar
        )

        XCTAssertEqual(merged.waterToday, 0)
    }

    func testAPendingSendWithoutAnAmountAddsNoMillilitres() {
        let now = PeardDate.parse("2026-10-07 12:00:00.000Z")!
        let merged = tallies().adding(pending: [send(amount: nil, queuedAt: now)], now: now, calendar: calendar)

        XCTAssertEqual(merged.waterToday, 0)
        XCTAssertEqual(merged.kinds.first?.mine.day, 1, "still a water moment")
    }

    func testTheOnDeviceFallbackSumsTodaysAmounts() {
        let now = PeardDate.parse("2026-10-07 12:00:00.000Z")!
        let posts = [
            Post(id: "1", pair: "p", author: "me", type: .event, eventKind: .water, created: now, amount: 330),
            Post(id: "2", pair: "p", author: "me", type: .event, eventKind: .water, created: now, amount: 500),
            Post(id: "3", pair: "p", author: "me", type: .event, eventKind: .water, created: now.addingTimeInterval(-86_400 * 3), amount: 1000),
        ]
        let periods = TallyPeriods.compute(posts: posts, now: now, calendar: calendar)

        XCTAssertEqual(periods.dayAmount, 830)
        XCTAssertEqual(periods.all, 3)
    }

    // MARK: Quick send

    func testOnlyWaterTakesAnAmount() {
        let beer = Moment(kind: .beer, emoji: "🍺", label: "Beer")
        let water = Moment(kind: .water, emoji: "💧", label: "Water", origin: .preset)

        var beerSend = QuickSend(moment: beer)
        beerSend.setAmount(330)
        var waterSend = QuickSend(moment: water)
        waterSend.setAmount(330)

        XCTAssertFalse(beerSend.takesAmount)
        XCTAssertNil(beerSend.amount)
        XCTAssertTrue(waterSend.takesAmount)
        XCTAssertEqual(waterSend.amount, 330)
    }

    func testPickingAnAmountHoldsTheSend() {
        var send = QuickSend(moment: Moment(kind: .water, emoji: "💧", label: "Water", origin: .preset))
        XCTAssertFalse(send.isHeld)

        send.setAmount(500)

        XCTAssertTrue(send.isHeld, "somebody choosing a size has not finished")
    }

    func testAnAmountCanBeClearedAndANonsenseOneIsRefused() {
        var send = QuickSend(moment: Moment(kind: .water, emoji: "💧", label: "Water", origin: .preset))
        send.setAmount(500)
        send.setAmount(nil)
        XCTAssertNil(send.amount)

        send.setAmount(WaterAmount.maximum + 1)
        XCTAssertNil(send.amount)
    }
}
