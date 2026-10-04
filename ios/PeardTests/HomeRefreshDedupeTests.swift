import XCTest
@testable import Peard
import PeardCore

/// The same request, twice, for nothing (issue #302's audit).
///
/// Each of these was a path where the home screen re-read what it had just
/// read: a return to the tab, a pull to refresh that delivered a queued moment,
/// a moment logged on Home. Counted at the transport, because "fetched once"
/// is a claim about requests, not about what ends up on screen.
@MainActor
final class HomeRefreshDedupeTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queueURL: URL!
    private var suiteName: String!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        CountingStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-dedupe-\(UUID().uuidString).json")
        suiteName = "peard-dedupe-\(UUID().uuidString)"
        let shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        shared.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-dedupe-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: CountingStubProtocol.makeSession()
        )
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: "pair1")
    }

    override func tearDown() async throws {
        for suffix in ["", ".inbox", ".cache"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: queueURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        CountingStubProtocol.reset()
        model = nil
        app = nil
        try await super.tearDown()
    }

    private var tallyRequests: Int { CountingStubProtocol.count(pathContaining: "/api/peard/tallies") }
    private var connectionRequests: Int {
        CountingStubProtocol.count(pathContaining: "/api/peard/connections", method: "GET")
    }

    private func queueAMoment() async {
        await app.enqueue(PendingSend(pairID: "pair1", authorID: "me", kind: .beer, emoji: "🍺", label: "Beer"))
    }

    /// Switching Home → Timeline → Home re-ran the whole load each time.
    func testReturningToTheHomeTabDoesNotFetchItAgain() async {
        await model.load()
        XCTAssertEqual(tallyRequests, 1)

        await model.load()

        XCTAssertEqual(tallyRequests, 1, "a tab switch is not a reason to fetch")
    }

    /// A pull to refresh that delivered a queued moment refreshed everything,
    /// then the delivery asked for a refresh of everything as well.
    func testAPullToRefreshThatDeliversFetchesEachThingOnce() async {
        await model.load()
        await queueAMoment()
        CountingStubProtocol.reset()

        await model.refreshAll()

        XCTAssertEqual(CountingStubProtocol.count(pathContaining: "/api/collections/posts/records", method: "POST"), 1)
        XCTAssertEqual(tallyRequests, 1)
        XCTAssertEqual(connectionRequests, 1)
    }

    /// Logging a moment on Home: the delivery refreshes the screen, and the
    /// send then fetched the posts and tallies again on its own account.
    func testLoggingAMomentFetchesTheTalliesOnce() async throws {
        await model.load()
        CountingStubProtocol.reset()

        model.tap(moment: try XCTUnwrap(MomentCatalogue.builtin.first { $0.kind == .beer }))
        await model.sendNow()

        XCTAssertEqual(CountingStubProtocol.count(pathContaining: "/api/collections/posts/records", method: "POST"), 1)
        XCTAssertEqual(tallyRequests, 1)
    }
}

/// Answers everything and counts what it was asked.
///
/// A post creation gets a real post back, so the queue sees a delivery; every
/// other request gets `{}`, which the screens treat as a failure to decode and
/// get on with — the tests care that a request was made, not what it said.
final class CountingStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [(method: String, path: String)] = []

    static func reset() {
        lock.lock()
        seen = []
        lock.unlock()
    }

    static func count(pathContaining fragment: String, method: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.filter { $0.path.contains(fragment) && (method == nil || $0.method == method) }.count
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.seen.append((method, path))
        Self.lock.unlock()

        var body = Data("{}".utf8)
        if method == "POST", path.hasSuffix("/api/collections/posts/records") {
            let post = Post(id: "sent1", pair: "pair1", author: "me", type: .event, eventKind: .beer, created: Date())
            body = (try? JSONEncoder.peard.encode(post)) ?? body
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
