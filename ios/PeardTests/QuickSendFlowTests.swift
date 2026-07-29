import XCTest
@testable import Peard
import PeardCore

/// The quick-send state machine, exercised through `HomeModel` rather than through
/// `QuickSend` alone.
///
/// `QuickSend` is pure and already covered in PeardCore. What was never covered is
/// the part that actually decides whether a moment is sent: the countdown task, the
/// hold-on-note rule, and the tap-while-pending behaviour. Those need the app target
/// because `HomeModel` is `@MainActor @Observable` and imports UIKit — which is
/// exactly why this bundle exists.
@MainActor
final class QuickSendFlowTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queue: SendQueue!

    private static let pairID = "pair1"

    /// A queue backed by a unique temporary file per test, so one test's leftovers
    /// cannot become another's starting state.
    private var storeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-tests-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        app = AppModel(sendQueue: queue)
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: Self.pairID)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        model = nil
        app = nil
        queue = nil
        try await super.tearDown()
    }

    private var beer: Moment {
        MomentCatalogue.builtin.first { $0.kind == .beer }!
    }

    private var coffee: Moment {
        MomentCatalogue.builtin.first { $0.kind == .coffee }!
    }

    // MARK: Starting the countdown

    func testTappingAMomentOpensTheWindowWithoutSendingYet() {
        model.tap(moment: beer)

        XCTAssertEqual(model.quickSend?.moment.kind, .beer)
        XCTAssertEqual(model.quickSendCaption, "Sending in 3…")
        XCTAssertEqual(model.quickSendProgress, 1)
    }

    func testTappingClearsAnyLeftoverNote() {
        model.noteText = "stale"
        model.tap(moment: beer)

        XCTAssertEqual(model.noteText, "")
    }

    /// The window is three seconds, and the caption counts down rather than
    /// sitting still — otherwise there is no way to tell how long is left.
    func testCaptionCountsDownAsTheWindowRuns() {
        model.tap(moment: beer)
        guard let send = model.quickSend else { return XCTFail("no pending send") }
        let started = send.startedAt

        XCTAssertEqual(send.caption(now: started), "Sending in 3…")
        XCTAssertEqual(send.caption(now: started.addingTimeInterval(1.2)), "Sending in 2…")
        XCTAssertEqual(send.caption(now: started.addingTimeInterval(2.5)), "Sending in 1…")
        XCTAssertEqual(send.caption(now: started.addingTimeInterval(3.0)), "Sending…")
    }

    // MARK: Holding on a note

    /// Somebody mid-sentence has not finished saying what they meant, so typing
    /// stops the clock.
    func testTypingANoteHoldsTheSend() {
        model.tap(moment: beer)
        model.noteText = "at the pub"
        model.noteDidChange()

        XCTAssertEqual(model.quickSend?.isHeld, true)
        XCTAssertEqual(model.quickSendCaption, "Tap send when ready")
        XCTAssertEqual(model.quickSendProgress, 1)
        // Held means held however long it sits there.
        XCTAssertFalse(model.quickSend!.shouldSend(now: Date().addingTimeInterval(60)))
    }

    /// Once held, clearing the field must not restart the clock: the text could
    /// otherwise be sent out from under somebody who was rewriting it.
    func testClearingTheNoteDoesNotReleaseTheHold() {
        model.tap(moment: beer)
        model.noteText = "a"
        model.noteDidChange()
        model.noteText = ""
        model.noteDidChange()

        XCTAssertEqual(model.quickSend?.isHeld, true)
        XCTAssertEqual(model.quickSendCaption, "Tap send when ready")
    }

    func testNoteChangeWithNoPendingSendIsHarmless() {
        model.noteText = "orphan"
        model.noteDidChange()

        XCTAssertNil(model.quickSend)
    }

    /// An empty edit — the field gaining and losing focus, say — must not hold.
    func testEmptyNoteDoesNotHold() {
        model.tap(moment: beer)
        model.noteDidChange()

        XCTAssertEqual(model.quickSend?.isHeld, false)
    }

    // MARK: Cancelling

    /// Requirement 12.6 — dismissing discards the text and creates nothing.
    func testCancellingDiscardsTheMomentAndTheNote() async {
        model.tap(moment: beer)
        model.noteText = "never mind"
        model.noteDidChange()

        model.cancelQuickSend()

        XCTAssertNil(model.quickSend)
        XCTAssertEqual(model.noteText, "")
        let queued = await queue.count
        XCTAssertEqual(queued, 0, "cancelling must not queue anything")
    }

    // MARK: Tapping while one is pending

    /// Tapping the same moment again means "go now", so the window closes and the
    /// moment is queued.
    func testTappingTheSameMomentAgainCommitsIt() async {
        model.tap(moment: beer)
        model.tap(moment: beer)

        await settle()

        XCTAssertNil(model.quickSend)
        let queued = await queue.pending
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, .beer)
    }

    /// Tapping a different moment commits what was pending and starts again, so
    /// moments can be logged back to back without waiting three seconds each.
    func testTappingADifferentMomentCommitsTheFirstAndStartsTheSecond() async {
        model.tap(moment: beer)
        model.tap(moment: coffee)

        await settle()

        let queued = await queue.pending
        XCTAssertEqual(queued.map(\.kind), [.beer])
        XCTAssertEqual(model.quickSend?.moment.kind, .coffee, "the second moment should now be counting down")
    }

    // MARK: Queueing

    /// The whole point of the queue: the moment is recorded on the device before
    /// any request is attempted, so nothing depends on the request succeeding.
    func testSendingQueuesTheMomentWithItsNote() async {
        model.tap(moment: beer)
        model.noteText = "round two"
        model.noteDidChange()

        await model.sendNow()

        let queued = await queue.pending
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.note, "round two")
        XCTAssertEqual(queued.first?.pairID, Self.pairID)
        XCTAssertEqual(queued.first?.emoji, "🍺")
        XCTAssertEqual(queued.first?.label, "Beer")
    }

    /// A queued moment has to appear in the timeline immediately, or logging
    /// something offline looks like it did nothing.
    func testQueuedMomentAppearsInTheTimelineStraightAway() async {
        model.tap(moment: beer)
        await model.sendNow()

        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertTrue(model.displayedPostIsPending)
        XCTAssertEqual(model.timeline.first?.eventKind, .beer)
    }

    /// And it has to move the tally, for the same reason.
    func testQueuedMomentCountsTowardsTheTally() async {
        XCTAssertEqual(model.myTallies.all, 0)

        model.tap(moment: beer)
        await model.sendNow()

        XCTAssertEqual(model.myTallies.day, 1)
        XCTAssertEqual(model.myTallies.all, 1)
        // The other side is untouched: a queued send is the user's own.
        XCTAssertEqual(model.partnerTallies.all, 0)
    }

    func testSendNowWithNothingPendingDoesNothing() async {
        await model.sendNow()

        let queued = await queue.count
        XCTAssertEqual(queued, 0)
    }

    // MARK: Pending summary copy

    func testPendingSummaryIsNilWhenTheQueueIsEmpty() {
        XCTAssertNil(model.pendingSummary)
    }

    func testPendingSummaryCountsQueuedMoments() async {
        model.tap(moment: beer)
        await model.sendNow()
        model.tap(moment: coffee)
        await model.sendNow()

        guard let summary = model.pendingSummary else { return XCTFail("expected a summary") }
        XCTAssertTrue(summary.contains("2 moments"), "got: \(summary)")
    }

    /// A pending moment whose custom kind is not published yet still draws its own
    /// emoji rather than falling back to the pear.
    func testPendingMomentKeepsItsOwnEmoji() async {
        let invented = Moment(kind: "sauna", emoji: "🧖", label: "Sauna", origin: .custom(recordID: nil))
        model.tap(moment: invented)
        await model.sendNow()

        guard let post = model.timeline.first else { return XCTFail("no timeline row") }
        XCTAssertEqual(model.emoji(for: post), "🧖")
        XCTAssertEqual(model.caption(for: post), "Sauna")
    }

    // MARK: Helpers

    /// Lets the detached commit tasks that `tap` spawns finish before asserting.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            if model.quickSend?.isHeld != true, await queue.count > 0 { return }
        }
    }
}
