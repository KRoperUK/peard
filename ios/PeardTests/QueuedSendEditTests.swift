import XCTest
@testable import Peard
import PeardCore

/// Editing and deleting a moment that is still waiting to send (#313 slice C).
///
/// These act on the queue, not the API: a queued send has no server record, so
/// there is no request to stub and nothing here may need one. The queue is
/// asserted directly as well as through `AppModel.pendingSends`, because the
/// mirror can be right while the file behind it is stale.
@MainActor
final class QueuedSendEditTests: XCTestCase {
    private var app: AppModel!
    private var queue: SendQueue!
    private var storeURL: URL!
    /// A keychain service of its own, so no real session leaks in and flushes the
    /// queue out from under the assertions (see `QuickSendFlowTests`).
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-queued-edit-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        sessionStore = KeychainSessionStore(service: "peard-queued-edit-test-\(UUID().uuidString)")
        sessionStore.clear()
        app = AppModel(sessionStore: sessionStore, sendQueue: queue)
        await app.attachSendQueue()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        sessionStore?.clear()
        sessionStore = nil
        app = nil
        queue = nil
        try await super.tearDown()
    }

    private func moment(id: String = "q1", kind: EventKind = .beer, note: String = "") -> PendingSend {
        PendingSend(
            id: id, pairID: "pair1", authorID: "me", kind: kind,
            emoji: "🍺", label: "Beer", note: note,
            queuedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    private func photo(id: String = "ph1", note: String = "") -> PendingSend {
        PendingSend(
            id: id, pairID: "pair1", authorID: "me", kind: EventKind(rawValue: ""),
            emoji: "📸", label: "Photo", note: note,
            queuedAt: Date(timeIntervalSince1970: 2_000), postType: .photo, hasPhoto: true
        )
    }

    // MARK: Edit

    func testEditChangesTheNote() async {
        await app.enqueue(moment())

        await app.editPendingSend(id: "q1", note: "  with oat milk  ", kind: .beer)

        XCTAssertEqual(app.pendingSends.first?.note, "with oat milk", "trimmed, as a sent note is")
        let queued = await queue.pending.first
        XCTAssertEqual(queued?.note, "with oat milk")
    }

    func testEditChangesTheKindAndRedrawsItsEmojiAndLabel() async {
        await app.enqueue(moment(kind: .beer))

        await app.editPendingSend(id: "q1", note: "", kind: .coffee)

        let edited = app.pendingSends.first
        XCTAssertEqual(edited?.kind, .coffee)
        XCTAssertEqual(edited?.emoji, "☕")
        XCTAssertEqual(edited?.label, "Coffee")
        XCTAssertEqual(edited?.postFields["event_kind"], "coffee")
    }

    func testEditingOnlyTheNoteKeepsTheKindsOwnEmojiAndLabel() async {
        await app.enqueue(moment(kind: .beer))

        await app.editPendingSend(id: "q1", note: "pint", kind: .beer)

        XCTAssertEqual(app.pendingSends.first?.emoji, "🍺")
        XCTAssertEqual(app.pendingSends.first?.label, "Beer")
    }

    func testEditKeepsIdentityAndQueuePosition() async {
        await app.enqueue(moment(id: "a"))
        await app.enqueue(moment(id: "b"))
        await app.enqueue(moment(id: "c"))

        await app.editPendingSend(id: "b", note: "middle", kind: .beer)

        XCTAssertEqual(app.pendingSends.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(app.pendingSends.map(\.note), ["", "middle", ""])
        XCTAssertEqual(app.pendingSends.first { $0.id == "b" }?.queuedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testEditingAStalledSendClearsItsFailureHistory() async {
        var stalled = moment().failed(with: "Server error 500", at: Date())
        stalled.attempts = PendingSend.maxAttempts
        await app.enqueue(stalled)
        XCTAssertTrue(app.pendingSends.first?.hasGivenUp ?? false)

        await app.editPendingSend(id: "q1", note: "fixed", kind: .beer)

        let revived = app.pendingSends.first
        XCTAssertEqual(revived?.attempts, 0)
        XCTAssertNil(revived?.lastAttemptAt)
        XCTAssertNil(revived?.lastError)
        XCTAssertEqual(revived?.hasGivenUp, false)
        XCTAssertEqual(revived?.note, "fixed")
    }

    func testEditingAPhotoSendChangesItsCaptionOnly() async {
        await app.enqueue(photo(note: "old"))

        await app.editPendingSend(id: "ph1", note: "new caption", kind: EventKind(rawValue: ""))

        let edited = app.pendingSends.first
        XCTAssertEqual(edited?.note, "new caption")
        XCTAssertEqual(edited?.postType, .photo)
        XCTAssertEqual(edited?.hasPhoto, true)
        XCTAssertEqual(edited?.emoji, "📸")
        XCTAssertEqual(edited?.label, "Photo")
    }

    func testEditingASendThatHasGoneDoesNothing() async {
        await app.enqueue(moment())

        await app.editPendingSend(id: "missing", note: "x", kind: .coffee)

        XCTAssertEqual(app.pendingSends.map(\.id), ["q1"])
        XCTAssertEqual(app.pendingSends.first?.note, "")
        let queued = await queue.pending
        XCTAssertEqual(queued.map(\.note), [""])
    }

    func testTheTimelineRowFollowsTheEdit() async {
        await app.enqueue(moment())

        await app.editPendingSend(id: "q1", note: "flat white", kind: .coffee)

        let post = app.pendingSends.first?.optimisticPost
        XCTAssertEqual(post?.id, "pending:q1")
        XCTAssertEqual(post?.note, "flat white")
        XCTAssertEqual(post?.eventKind, .coffee)
    }

    // MARK: Timeline rows

    private func historyModel() -> HistoryModel {
        HistoryModel(
            api: APIClient(baseURL: URL(string: "http://127.0.0.1:8090")!, tokenProvider: nil),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil,
            pendingSends: { [app = app!] in app.pendingSends(forConnection: "pair1") }
        )
    }

    func testAPendingRowMapsBackToItsQueuedSend() async {
        await app.enqueue(moment(id: "a"))
        await app.enqueue(moment(id: "b", note: "second"))
        let model = historyModel()

        let row = app.pendingSends[1].optimisticPost

        XCTAssertEqual(model.pendingSend(for: row)?.id, "b")
        XCTAssertEqual(model.pendingSend(for: row)?.note, "second")
    }

    func testASentRowHasNoQueuedSend() async {
        await app.enqueue(moment())
        let sent = Post(
            id: "q1", pair: "pair1", author: "me", type: .event, eventKind: .beer,
            created: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertNil(historyModel().pendingSend(for: sent), "an id that merely matches is not a pending row")
    }

    func testARowForASendThatHasGoneMapsToNothing() async {
        await app.enqueue(moment())
        let model = historyModel()
        let row = app.pendingSends[0].optimisticPost

        await app.deletePendingSend(id: "q1")

        XCTAssertNil(model.pendingSend(for: row))
    }

    // MARK: Delete

    func testDeleteRemovesTheSendFromTheQueue() async {
        await app.enqueue(moment(id: "a"))
        await app.enqueue(moment(id: "b"))

        await app.deletePendingSend(id: "a")

        XCTAssertEqual(app.pendingSends.map(\.id), ["b"])
        let queued = await queue.pending
        XCTAssertEqual(queued.map(\.id), ["b"], "the queue itself, not only the mirror")
    }

    func testDeletingASendThatHasGoneDoesNothing() async {
        await app.enqueue(moment())

        await app.deletePendingSend(id: "missing")

        XCTAssertEqual(app.pendingSends.map(\.id), ["q1"])
    }

    func testDeletingAPhotoSendPrunesItsPhotoFile() async throws {
        let send = photo(id: "ph-\(UUID().uuidString)")
        try app.pendingPhotos.save(Data([0xFF, 0xD8, 0xFF]), for: send.id)
        await app.enqueue(send)
        XCTAssertNotNil(app.pendingPhotos.load(for: send.id))

        await app.deletePendingSend(id: send.id)

        XCTAssertTrue(app.pendingSends.isEmpty)
        XCTAssertNil(app.pendingPhotos.load(for: send.id), "the JPEG must not outlive its send")
    }

    func testDeletingAnotherSendKeepsAPhotoFileStillQueued() async throws {
        let kept = photo(id: "ph-\(UUID().uuidString)")
        try app.pendingPhotos.save(Data([0xFF, 0xD8, 0xFF]), for: kept.id)
        await app.enqueue(kept)
        await app.enqueue(moment())
        defer { try? FileManager.default.removeItem(at: app.pendingPhotos.url(for: kept.id)) }

        await app.deletePendingSend(id: "q1")

        XCTAssertEqual(app.pendingSends.map(\.id), [kept.id])
        XCTAssertNotNil(app.pendingPhotos.load(for: kept.id))
    }
}
