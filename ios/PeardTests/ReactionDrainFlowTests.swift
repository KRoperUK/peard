import XCTest
@testable import Peard
import PeardCore

/// The chain #376 relied on: the network coming back drains the notification
/// reaction queue (#384).
///
/// Nothing covered it before. `ReachabilityTests` exercises the reachability
/// callback in isolation and `ReactionQueueTests` (in PeardCore) exercises the
/// queue; this ties the two together through `AppModel` — a reaction that could
/// not be sent, a reachability `onChange(online: true)`, and the request that
/// follows. The queue is drained on regain, on foreground and on a silent push;
/// this is the regain one, which had no test at all.
@MainActor
final class ReactionDrainFlowTests: XCTestCase {
    private static let userID = "me"

    private var app: AppModel!
    private var sendQueue: SendQueue!
    private var reactions: ReactionQueue!
    private var sessionStore: KeychainSessionStore!
    private var shared: SharedStore!
    private var suiteName: String!
    private var sendStoreURL: URL!
    private var reactionStoreURL: URL!
    private var inboxURL: URL!

    override func setUp() async throws {
        try await super.setUp()

        sendStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-drain-sends-\(UUID().uuidString).json")
        reactionStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-drain-reactions-\(UUID().uuidString).json")
        inboxURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-drain-inbox-\(UUID().uuidString).json")

        sendQueue = SendQueue(store: FilePendingSendStore(url: sendStoreURL))

        // A throwaway defaults suite and keychain service, for the same reason
        // as the other app-target suites: sharing the device's would make these
        // pass or fail depending on what somebody last did in the simulator.
        suiteName = "peard-reaction-drain-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        sessionStore = KeychainSessionStore(service: "peard-reaction-drain-\(UUID().uuidString)")
        sessionStore.clear()
        // A flush is skipped entirely without a session, so the drain under test
        // needs one.
        try sessionStore.save(token: "token", userID: Self.userID)

        app = AppModel(
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: sendQueue,
            momentInbox: MomentInbox(url: inboxURL),
            session: ReactionDrainStubProtocol.makeSession()
        )

        // A queue over a temporary file, not the App Group one: that is the
        // device's real reaction queue, and seeding it would send for real.
        reactions = ReactionQueue(store: FilePendingReactionStore(url: reactionStoreURL))
        app.push.reactionQueue = reactions

        await app.attachSendQueue()
        // The test drives the transitions by hand; a real path update arriving
        // underneath it would make the result a race.
        app.reachability.stop()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sendStoreURL)
        try? FileManager.default.removeItem(at: reactionStoreURL)
        try? FileManager.default.removeItem(at: inboxURL)
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        sessionStore = nil
        shared = nil
        suiteName = nil
        reactions = nil
        sendQueue = nil
        app = nil
        try await super.tearDown()
    }

    // MARK: Regaining connectivity

    /// The behaviour #376 depended on: a reaction tapped while offline is still
    /// there, and the network coming back is what sends it.
    func testConnectivityRegainDrainsAQueuedReaction() async {
        // A tap that could not reach the server. The drain is what sends it.
        await reactions.enqueue(PendingReaction(postID: "p1", userID: Self.userID, kind: .cheers))
        ReactionDrainStubProtocol.reset()

        // Down, then back up.
        app.reachability.simulatePathUpdate(isOnline: false)
        app.reachability.simulatePathUpdate(isOnline: true)
        await waitUntil { ReactionDrainStubProtocol.reactionPosts == 1 }

        XCTAssertEqual(
            ReactionDrainStubProtocol.reactionPosts, 1,
            "the network coming back must send the reaction that was waiting"
        )
        let remaining = await reactions.pending()
        XCTAssertTrue(remaining.isEmpty, "and it must leave the queue once it landed")
    }

    /// And it is not sent twice: the queue is empty by then, so a second regain
    /// has nothing to deliver. This is the idempotency half of the same chain.
    func testASecondRegainDoesNotResendIt() async {
        await reactions.enqueue(PendingReaction(postID: "p1", userID: Self.userID, kind: .cheers))
        ReactionDrainStubProtocol.reset()

        app.reachability.simulatePathUpdate(isOnline: false)
        app.reachability.simulatePathUpdate(isOnline: true)
        await waitUntil { ReactionDrainStubProtocol.reactionPosts == 1 }

        // Down and up again.
        app.reachability.simulatePathUpdate(isOnline: false)
        app.reachability.simulatePathUpdate(isOnline: true)
        await pause()

        XCTAssertEqual(
            ReactionDrainStubProtocol.reactionPosts, 1,
            "an empty queue must not produce a duplicate on a second regain"
        )
    }

    /// Going *offline* is not a reason to send: the handler has nothing to do on
    /// the way down, and a drain that fired there would only fail.
    func testGoingOfflineSendsNothing() async {
        await reactions.enqueue(PendingReaction(postID: "p1", userID: Self.userID, kind: .cheers))
        ReactionDrainStubProtocol.reset()

        app.reachability.simulatePathUpdate(isOnline: false)
        await pause()

        XCTAssertEqual(ReactionDrainStubProtocol.reactionPosts, 0)
        let remaining = await reactions.pending()
        XCTAssertEqual(remaining.count, 1, "the reaction waits for the way back up")
    }

    // MARK: Helpers

    /// Polls until the condition holds, for the detached task the reachability
    /// handler spawns — bounded so a regression fails rather than hangs.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Lets anything already started finish, for the negative assertions.
    private func pause() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Counts the reaction creates the drain makes, and answers each with the record
/// PocketBase would echo back. Every other request gets the same shape, which is
/// enough because the flush under test has nothing else queued.
final class ReactionDrainStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var posts = 0

    /// Reaction creates seen so far, across tests.
    static var reactionPosts: Int {
        lock.lock()
        defer { lock.unlock() }
        return posts
    }

    static func reset() {
        lock.lock()
        posts = 0
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReactionDrainStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isReactionCreate = request.httpMethod == "POST"
            && (request.url?.path.contains("reactions") ?? false)

        Self.lock.lock()
        if isReactionCreate { Self.posts += 1 }
        Self.lock.unlock()

        // `api.create` decodes the created record, so a 200 with the echo is
        // what makes the drain count it as delivered and remove it.
        let json = #"{"id":"r1","post":"p1","user":"me","kind":"cheers"}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
