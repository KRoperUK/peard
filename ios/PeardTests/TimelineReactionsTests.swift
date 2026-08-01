import XCTest
@testable import Peard
import PeardCore

/// Reactions on the timeline, and the one rule that makes them survive a
/// pull-to-refresh.
///
/// The bug this pins: `reload()` used to empty the reaction map and then fetch.
/// Pull-to-refresh runs both requests inside a task SwiftUI cancels the moment
/// the refresh control retracts — the posts request finished, the reactions one
/// was cancelled, and every reaction vanished until the app was relaunched. It
/// took a device log to see, because the cancellation was swallowed on purpose.
@MainActor
final class TimelineReactionsTests: XCTestCase {
    private var model: HistoryModel!

    private static let mine = Post(
        id: "mine", pair: "pair1", author: "me", type: .event, eventKind: .beer, created: Date()
    )
    private static let theirs = Post(
        id: "theirs", pair: "pair1", author: "them", type: .event, eventKind: .coffee, created: Date()
    )

    override func setUp() {
        super.setUp()
        TimelineStubProtocol.reset()
        model = HistoryModel(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8090")!,
                tokenProvider: nil,
                session: TimelineStubProtocol.makeSession()
            ),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil
        )
    }

    override func tearDown() {
        TimelineStubProtocol.reset()
        model = nil
        super.tearDown()
    }

    // MARK: Loading

    func testReactionsArriveWithTheFirstPage() async {
        TimelineStubProtocol.route(posts: [Self.mine, Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "me", kind: .heart),
        ])

        await model.loadFirstPage()

        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.heart])
        XCTAssertTrue(model.reactionKinds(for: Self.mine).isEmpty)
    }

    /// Several people using the same kind is one emoji on the row, not three.
    func testTheSameKindFromSeveralPeopleIsShownOnce() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "me", kind: .heart),
            reaction(id: "r2", post: "theirs", user: "someone", kind: .heart),
            reaction(id: "r3", post: "theirs", user: "another", kind: .cheers),
        ])

        await model.loadFirstPage()

        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.heart, .cheers])
    }

    // MARK: The regression

    /// A reactions request that fails — cancelled by the refresh, or anything
    /// else — must leave what is on screen alone. Blanking first and fetching
    /// second is what emptied the timeline.
    func testAFailedReactionsLoadKeepsWhatIsAlreadyShown() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "me", kind: .heart),
        ])
        await model.loadFirstPage()
        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.heart])

        TimelineStubProtocol.failReactions(with: URLError(.cancelled))
        await model.reload()

        XCTAssertEqual(
            model.reactionKinds(for: Self.theirs), [.heart],
            "a cancelled reactions fetch must not clear the ones already drawn"
        )
    }

    /// And the reverse: a reaction genuinely taken away does go, or the row
    /// would keep a heart nobody stands behind.
    func testAReactionThatIsGoneIsRemovedOnReload() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "me", kind: .heart),
        ])
        await model.loadFirstPage()

        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.reload()

        XCTAssertTrue(model.reactionKinds(for: Self.theirs).isEmpty)
    }

    // MARK: Reacting

    /// Drawn from the accepted write rather than from the reconciliation, which
    /// can be cancelled exactly like the one above.
    func testReactingShowsImmediately() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.loadFirstPage()

        TimelineStubProtocol.failReactions(with: URLError(.cancelled))
        await model.toggleReaction(to: Self.theirs, kind: .cheers)

        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.cheers])
        XCTAssertNil(model.error, "the write succeeded; a cancelled re-read is not the user's problem")
    }

    /// Kinds are independent: a second one adds to the row rather than
    /// replacing the first.
    func testASecondKindAddsRatherThanReplaces() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.loadFirstPage()

        TimelineStubProtocol.failReactions(with: URLError(.cancelled))
        await model.toggleReaction(to: Self.theirs, kind: .cheers)
        await model.toggleReaction(to: Self.theirs, kind: .heart)

        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.cheers, .heart])
    }

    // MARK: Taking one back

    func testReactingAgainWithTheSameKindTakesItBack() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "me", kind: .cheers),
        ])
        await model.loadFirstPage()
        XCTAssertTrue(model.hasReacted(to: Self.theirs, kind: .cheers))

        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.toggleReaction(to: Self.theirs, kind: .cheers)

        XCTAssertFalse(model.hasReacted(to: Self.theirs, kind: .cheers))
        XCTAssertTrue(model.reactionKinds(for: Self.theirs).isEmpty)
        XCTAssertEqual(TimelineStubProtocol.lastDeletedID, "r1")
    }

    /// Somebody else's reaction of the same kind is not yours to remove, and
    /// must not make the control think it has something to take back.
    func testAnotherPersonsReactionIsNotYoursToTakeBack() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "r1", post: "theirs", user: "someone", kind: .heart),
        ])
        await model.loadFirstPage()

        XCTAssertFalse(model.hasReacted(to: Self.theirs, kind: .heart))
        XCTAssertEqual(model.reactionKinds(for: Self.theirs), [.heart], "it is still shown, just not yours")
    }

    /// The window this is really about: react, have the reconciliation
    /// cancelled so only the placeholder id is known, then immediately undo. A
    /// made-up id must never be sent to the server.
    func testUndoWorksBeforeTheServerIdIsKnown() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.loadFirstPage()

        TimelineStubProtocol.failReactions(with: URLError(.cancelled))
        await model.toggleReaction(to: Self.theirs, kind: .cheers)
        XCTAssertTrue(model.hasReacted(to: Self.theirs, kind: .cheers), "drawn from the accepted write")

        // The re-read now works, so the real id becomes knowable.
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [
            reaction(id: "server-id", post: "theirs", user: "me", kind: .cheers),
        ])
        await model.toggleReaction(to: Self.theirs, kind: .cheers)

        XCTAssertEqual(TimelineStubProtocol.lastDeletedID, "server-id", "never the placeholder")
        XCTAssertFalse(model.hasReacted(to: Self.theirs, kind: .cheers))
    }

    /// And if the id still cannot be learned, nothing is sent at all — better a
    /// reaction that stays until the next load than a delete aimed at an id the
    /// server has never heard of.
    func testUndoSendsNothingWhenTheRealIDCannotBeLearned() async {
        TimelineStubProtocol.route(posts: [Self.theirs], reactions: [])
        await model.loadFirstPage()

        TimelineStubProtocol.failReactions(with: URLError(.cancelled))
        await model.toggleReaction(to: Self.theirs, kind: .cheers)
        await model.toggleReaction(to: Self.theirs, kind: .cheers)

        XCTAssertNil(TimelineStubProtocol.lastDeletedID)
    }

    // MARK: Who may

    func testYouCanReactToSomebodyElsesMomentButNotYourOwn() {
        XCTAssertTrue(model.canReact(to: Self.theirs))
        XCTAssertFalse(model.canReact(to: Self.mine))
        XCTAssertTrue(model.canEdit(Self.mine))
        XCTAssertFalse(model.canEdit(Self.theirs))
    }

    // MARK: Helpers

    private func reaction(id: String, post: String, user: String, kind: ReactionKind) -> Reaction {
        Reaction(id: id, post: post, user: user, kind: kind)
    }
}

/// Routes the two collections this screen reads, so a test can make one succeed
/// and the other fail — which is the whole shape of the bug above.
final class TimelineStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var postsJSON = #"{"items":[]}"#
    nonisolated(unsafe) private static var reactionsJSON = #"{"items":[]}"#
    nonisolated(unsafe) private static var reactionsError: Error?
    nonisolated(unsafe) private static var deletedID: String?

    /// The id the last DELETE was aimed at, which is the whole question when a
    /// reaction may still be carrying a locally-made-up one.
    static var lastDeletedID: String? {
        lock.lock()
        defer { lock.unlock() }
        return deletedID
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimelineStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func route(posts: [Post], reactions: [Reaction]) {
        lock.lock()
        postsJSON = envelope(posts)
        reactionsJSON = envelope(reactions)
        reactionsError = nil
        lock.unlock()
    }

    static func failReactions(with error: Error) {
        lock.lock()
        reactionsError = error
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        postsJSON = #"{"items":[]}"#
        reactionsJSON = #"{"items":[]}"#
        reactionsError = nil
        deletedID = nil
        lock.unlock()
    }

    private static func envelope<Item: Encodable>(_ items: [Item]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            try container.encode(formatter.string(from: date))
        }
        let body = (try? encoder.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return #"{"page":1,"perPage":30,"totalItems":\#(items.count),"totalPages":1,"items":\#(body)}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // Reading reactions and writing one hit the same collection, and only
        // the read is the thing being failed here: `failReactions` stands in for
        // a cancelled refresh, which cancels the fetch, not a write the server
        // has already accepted.
        let isRead = request.httpMethod == "GET"
        Self.lock.lock()
        if request.httpMethod == "DELETE" {
            Self.deletedID = request.url?.lastPathComponent
        }
        let error = path.contains("reactions") && isRead ? Self.reactionsError : nil
        let json: String
        if !isRead {
            // PocketBase echoes the created record back.
            json = #"{"id":"created","post":"theirs","user":"me","kind":"cheers"}"#
        } else {
            json = path.contains("reactions") ? Self.reactionsJSON : Self.postsJSON
        }
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
