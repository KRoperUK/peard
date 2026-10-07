import XCTest
@testable import Peard
import PeardCore

/// A moment logged offline shows in the timeline beside the ones that have
/// landed, marked as queued, and offers none of the server-record actions
/// until it has been accepted (#313 slice B).
@MainActor
final class TimelineQueuedSendsTests: XCTestCase {
    private static let sent = Post(
        id: "sent1", pair: "pair1", author: "me", type: .event, eventKind: .beer,
        created: Date(timeIntervalSince1970: 1_000)
    )

    private func pending(
        id: String = "q1",
        kind: EventKind = .coffee,
        note: String = "",
        hasPhoto: Bool = false,
        queuedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> PendingSend {
        PendingSend(
            id: id,
            pairID: "pair1",
            authorID: "me",
            kind: kind,
            emoji: kind == .coffee ? "☕️" : "🍺",
            label: kind == .coffee ? "Coffee" : "Beer",
            note: note,
            queuedAt: queuedAt,
            postType: hasPhoto && kind.rawValue.isEmpty ? .photo : .event,
            hasPhoto: hasPhoto
        )
    }

    private func model(
        pending: [PendingSend],
        offline: Bool = true,
        customKinds: [MomentKind] = []
    ) -> HistoryModel {
        TimelineStubProtocol.reset()
        return HistoryModel(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8090")!,
                tokenProvider: nil,
                session: TimelineStubProtocol.makeSession()
            ),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: customKinds,
            connection: nil,
            pendingSends: { pending },
            isOffline: { offline }
        )
    }

    override func tearDown() {
        TimelineStubProtocol.reset()
        super.tearDown()
    }

    func testQueuedSendAppearsBesideSentMoments() async {
        let subject = model(pending: [pending()])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        let ids = subject.days.flatMap { $0.posts }.map(\.id)
        XCTAssertTrue(ids.contains("sent1"))
        XCTAssertTrue(ids.contains("pending:q1"))
    }

    func testQueuedSendSortsNewestFirst() async {
        // Queued at 2000, sent at 1000 — the queued one is newer and goes first.
        let subject = model(pending: [pending()])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        let ids = subject.days.flatMap { $0.posts }.map(\.id)
        XCTAssertEqual(ids.first, "pending:q1")
    }

    func testPendingRowIsRecognised() async {
        let subject = model(pending: [pending()])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        let queued = subject.days.flatMap { $0.posts }.first { $0.id == "pending:q1" }
        XCTAssertNotNil(queued)
        XCTAssertTrue(subject.isPending(queued!))
        XCTAssertFalse(subject.isPending(Self.sent))
    }

    func testPendingRowOffersNoEditOrDelete() async {
        let subject = model(pending: [pending()])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        let queued = subject.days.flatMap { $0.posts }.first { $0.id == "pending:q1" }!
        // Yours, so you could edit a *sent* one — but a queued send has no
        // server record to edit until it lands.
        XCTAssertTrue(subject.canEdit(Self.sent))
        XCTAssertFalse(subject.canEdit(queued))
    }

    func testIndicatorFollowsConnectivity() async {
        let offlineModel = model(pending: [pending()], offline: true)
        XCTAssertTrue(offlineModel.pendingIndicatorIsOffline)

        let onlineModel = model(pending: [pending()], offline: false)
        XCTAssertFalse(onlineModel.pendingIndicatorIsOffline)
    }

    func testAuthorFilterHidesAndKeepsQueuedSends() async {
        let subject = model(pending: [pending()])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        // Yours: kept when filtering to you, hidden when filtering to someone else.
        await subject.apply(.none.choosing(author: "me"))
        XCTAssertTrue(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })

        await subject.apply(.none.choosing(author: "them"))
        XCTAssertFalse(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })
    }

    func testKindFilterNarrowsQueuedSends() async {
        let subject = model(pending: [pending(kind: .coffee)])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        await subject.apply(.none.choosing(kind: .coffee))
        XCTAssertTrue(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })

        await subject.apply(.none.choosing(kind: .beer))
        XCTAssertFalse(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })
    }

    func testPhotosOnlyFilterHidesPlainQueuedSends() async {
        let subject = model(pending: [pending(hasPhoto: false)])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        await subject.apply(.none.choosingPhotos(true))
        XCTAssertFalse(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })
    }

    func testSearchMatchesQueuedNote() async {
        let subject = model(pending: [pending(note: "flat white please")])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        await subject.apply(.none.searching("flat white", catalogue: subject.moments))
        XCTAssertTrue(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })

        await subject.apply(.none.searching("espresso", catalogue: subject.moments))
        XCTAssertFalse(subject.days.flatMap { $0.posts }.contains { $0.id == "pending:q1" })
    }

    func testNoPendingSendsLeavesTimelineUnchanged() async {
        let subject = model(pending: [])
        TimelineStubProtocol.route(posts: [Self.sent], reactions: [])
        await subject.loadFirstPage()

        let ids = subject.days.flatMap { $0.posts }.map(\.id)
        XCTAssertEqual(ids, ["sent1"])
    }
}
