import XCTest
@testable import PeardCore

/// Logging a moment after it happened: what the client sends, what it reads
/// back, and where a rewound moment counts.
final class RewindTests: XCTestCase {
    private let decoder = JSONDecoder.peard
    private let logged = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Reading posts

    func testAPostFromAnOlderServerHappenedWhenItWasLogged() throws {
        let post = try decoder.decode(Post.self, from: Data("""
        {"id":"p1","pair":"x","author":"a","type":"event","event_kind":"beer",
         "created":"2026-09-27 12:00:00.000Z"}
        """.utf8))

        XCTAssertEqual(post.happenedAt, post.created)
        XCTAssertFalse(post.rewound)
    }

    func testARewoundPostCarriesBothTimes() throws {
        let post = try decoder.decode(Post.self, from: Data("""
        {"id":"p1","pair":"x","author":"a","type":"event","event_kind":"beer",
         "created":"2026-09-27 12:00:00.000Z",
         "happened_at":"2026-09-27 09:30:00.000Z"}
        """.utf8))

        XCTAssertEqual(post.created.timeIntervalSince(post.happenedAt), 2.5 * 3600, accuracy: 0.001)
        XCTAssertTrue(post.rewound)
    }

    /// Within a minute of arriving is still live: a request in flight, or a
    /// clock a few seconds out, is not a rewind.
    func testAPostHappenedMomentsBeforeArrivingIsNotRewound() {
        let post = Post(id: "p", pair: "x", author: "a", type: .event,
                        created: logged, happenedAt: logged.addingTimeInterval(-45))
        XCTAssertFalse(post.rewound)
    }

    func testAWidgetPostFallsBackToWhenItWasLogged() throws {
        let post = try decoder.decode(WidgetFeed.FeedPost.self, from: Data("""
        {"id":"p1","type":"event","created":"2026-09-27 12:00:00.000Z"}
        """.utf8))

        XCTAssertEqual(post.happenedOrCreated, post.created)
        XCTAssertFalse(post.rewound)
    }

    // MARK: The rules

    func testTheRangeIsTheDayBeforeItWasLogged() {
        let range = Rewind.range(loggedAt: logged)
        XCTAssertEqual(range.upperBound, logged)
        XCTAssertEqual(logged.timeIntervalSince(range.lowerBound), 24 * 3600)
    }

    func testAFewSecondsBackIsNotARewind() {
        XCTAssertFalse(Rewind.isRewound(logged.addingTimeInterval(-30), loggedAt: logged))
        XCTAssertTrue(Rewind.isRewound(logged.addingTimeInterval(-120), loggedAt: logged))
    }

    // MARK: The send window

    func testPickingATimeHoldsTheSend() {
        var send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: logged)
        send.rewind(to: logged.addingTimeInterval(-3600), now: logged)

        XCTAssertTrue(send.isHeld, "a send must not go out while somebody is picking a time")
        XCTAssertFalse(send.shouldSend(now: logged.addingTimeInterval(10)))
        XCTAssertEqual(send.happenedAt, logged.addingTimeInterval(-3600))
    }

    func testPickingNowClearsTheRewind() {
        var send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: logged)
        send.rewind(to: logged.addingTimeInterval(-3600), now: logged)
        send.rewind(to: nil, now: logged)

        XCTAssertNil(send.happenedAt)
    }

    func testATimeBeyondTheWindowIsPulledBackInside() {
        var send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: logged)
        send.rewind(to: logged.addingTimeInterval(-30 * 3600), now: logged)

        XCTAssertEqual(send.happenedAt, logged.addingTimeInterval(-24 * 3600))
    }

    // MARK: The queue

    func testARewoundSendTellsTheServerWhenItHappened() throws {
        let at = logged.addingTimeInterval(-2 * 3600)
        let send = PendingSend(pairID: "x", authorID: "a", kind: .beer, emoji: "🍺", label: "Beer",
                               queuedAt: logged, happenedAt: at)

        let wire = try XCTUnwrap(send.postFields["happened_at"])
        let parsed = try XCTUnwrap(ISO8601DateFormatter.withFractionalSeconds.date(from: wire))
        XCTAssertEqual(parsed.timeIntervalSince(at), 0, accuracy: 0.001)
    }

    func testALiveSendLeavesTheTimeToTheServer() {
        let send = PendingSend(pairID: "x", authorID: "a", kind: .beer, emoji: "🍺", label: "Beer")
        XCTAssertNil(send.postFields["happened_at"])
    }

    func testARewoundSendSurvivesARelaunch() throws {
        let at = logged.addingTimeInterval(-2 * 3600)
        let send = PendingSend(pairID: "x", authorID: "a", kind: .beer, emoji: "🍺", label: "Beer",
                               queuedAt: logged, happenedAt: at)

        let data = try JSONEncoder.peard.encode(send)
        let decoded = try decoder.decode(PendingSend.self, from: data)
        XCTAssertEqual(decoded.happenedAt?.timeIntervalSince1970 ?? 0, at.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAQueuedFileFromBeforeRewindingStillLoads() throws {
        let send = try decoder.decode(PendingSend.self, from: Data("""
        {"id":"s1","pair":"x","author":"a","kind":"beer","emoji":"🍺","label":"Beer","note":"",
         "queued_at":"2026-09-27 12:00:00.000Z","attempts":0}
        """.utf8))
        XCTAssertNil(send.happenedAt)
        XCTAssertEqual(send.happenedOrQueuedAt, send.queuedAt)
    }

    func testTheOptimisticRowShowsTheChip() {
        let send = PendingSend(pairID: "x", authorID: "a", kind: .beer, emoji: "🍺", label: "Beer",
                               queuedAt: logged, happenedAt: logged.addingTimeInterval(-3600))
        let post = send.optimisticPost

        XCTAssertTrue(post.rewound)
        XCTAssertEqual(post.happenedAt, logged.addingTimeInterval(-3600))
        XCTAssertEqual(post.created, logged)
    }

    // MARK: Counting

    /// Logged today, but it happened before today started.
    func testTalliesCountWhenAMomentHappened() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 1))!
        let post = Post(id: "p", pair: "x", author: "a", type: .event, eventKind: .beer,
                        created: now, happenedAt: now.addingTimeInterval(-3 * 3600))

        let periods = TallyPeriods.compute(posts: [post], now: now, calendar: calendar)
        XCTAssertEqual(periods.day, 0)
        XCTAssertEqual(periods.all, 1)
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
