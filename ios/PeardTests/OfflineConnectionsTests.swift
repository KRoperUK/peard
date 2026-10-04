import XCTest
@testable import Peard
import PeardCore

/// What a launch shows when the connection list cannot be fetched (#300).
///
/// The bug: in airplane mode the app said "No connections yet" to somebody with
/// connections. It had not been told they had none — it had failed to ask. So
/// there are two things to keep apart, and they are kept apart here: a failed
/// load with a cache behind it shows the cached list, and a failed load without
/// one shows neither the list nor the empty state.
@MainActor
final class OfflineConnectionsTests: XCTestCase {
    private var app: AppModel!
    private var cacheURL: URL!
    private var cache: FileConnectionCache!
    private var suiteName: String!
    private var shared: SharedStore!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-offline-\(UUID().uuidString).json")
        cache = FileConnectionCache(url: cacheURL)
        suiteName = "peard-offline-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        // A successful load lands on home, which asks for notification
        // permission; the system prompt never answers in a test host.
        shared.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-offline-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        ConnectionsStubProtocol.reset()
        app = makeApp()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheURL)
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        ConnectionsStubProtocol.reset()
        sessionStore = nil
        shared = nil
        cache = nil
        cacheURL = nil
        app = nil
        try await super.tearDown()
    }

    /// An app pointed at the stub, so the fetch can be made to succeed or fail.
    private func makeApp() -> AppModel {
        AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: cacheURL.appendingPathExtension("queue"))),
            connectionCache: cache,
            session: ConnectionsStubProtocol.makeSession()
        )
    }

    private func connection(_ pair: String, name: String? = nil) -> Connection {
        Connection(
            pair: pair,
            name: name,
            created: Date(timeIntervalSince1970: 1_700_000_000),
            role: .member,
            members: [
                Connection.Member(user: "me", name: "Me", role: .member, isYou: true),
                Connection.Member(user: "u1", name: "Sam"),
            ]
        )
    }

    private func seedCache(_ connections: [Connection], at date: Date) {
        cache.saveConnections(connections, at: date)
    }

    // MARK: Offline with a cache

    /// The heart of #300: the connections come back, and the app lands on the one
    /// that was last on screen rather than on a screen that says there are none.
    func testAnOfflineLaunchRestoresTheCachedConnections() async {
        seedCache([connection("pair1", name: "Flatmates")], at: Date(timeIntervalSince1970: 1_700_000_000))
        shared.selectedConnectionID = "pair1"
        ConnectionsStubProtocol.fail(with: URLError(.notConnectedToInternet))

        await app.resolveMembership()

        XCTAssertEqual(app.connections.map(\.pair), ["pair1"])
        XCTAssertEqual(app.phase, .home(pairID: "pair1"))
        XCTAssertTrue(app.membershipFailed, "so the screen can offer a retry")
    }

    /// "Last updated" needs a time, and it has to be the server's answer rather
    /// than the moment of the read, or an old list reads as fresh.
    func testTheRestoredListIsMarkedWithWhenItWasLastFetched() async {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        seedCache([connection("pair1")], at: fetched)
        shared.selectedConnectionID = "pair1"
        ConnectionsStubProtocol.fail(with: URLError(.notConnectedToInternet))

        await app.resolveMembership()

        XCTAssertTrue(app.connectionsFromCache)
        XCTAssertEqual(app.connectionsUpdatedAt?.timeIntervalSince1970 ?? 0, fetched.timeIntervalSince1970, accuracy: 1)
    }

    /// A cached list with nothing remembered about where the user was stays on the
    /// connections screen: guessing a connection would be worse than asking.
    func testAnOfflineLaunchWithoutARememberedConnectionStaysOnTheList() async {
        seedCache([connection("pair1")], at: Date())
        shared.selectedConnectionID = nil
        ConnectionsStubProtocol.fail(with: URLError(.notConnectedToInternet))

        await app.resolveMembership()

        XCTAssertEqual(app.connections.map(\.pair), ["pair1"])
        XCTAssertEqual(app.phase, .connections)
    }

    // MARK: Offline with nothing cached

    /// Not the empty state. The list is empty *and* the load failed, which is a
    /// different thing from being told there is nothing — the screen keys the
    /// "No connections yet" copy off that difference.
    func testAFailedLoadWithNoCacheLeavesTheListEmptyAndFlagged() async {
        ConnectionsStubProtocol.fail(with: URLError(.notConnectedToInternet))

        await app.resolveMembership()

        XCTAssertTrue(app.connections.isEmpty)
        XCTAssertTrue(app.membershipFailed)
        XCTAssertFalse(app.connectionsFromCache, "nothing was restored, so nothing is cached")
        XCTAssertNil(app.connectionsUpdatedAt)
        XCTAssertEqual(app.phase, .connections)
    }

    // MARK: A successful fetch

    /// The other half of the feature: a list nobody ever writes is a list that is
    /// never there to read, and that failure is invisible — it only shows up the
    /// next time somebody is offline.
    func testASuccessfulLoadIsCachedAndNotMarkedStale() async {
        ConnectionsStubProtocol.serve([connection("pair1", name: "Flatmates")])

        await app.resolveMembership()

        XCTAssertEqual(app.connections.map(\.pair), ["pair1"])
        XCTAssertEqual(app.phase, .home(pairID: "pair1"))
        XCTAssertFalse(app.membershipFailed)
        XCTAssertFalse(app.connectionsFromCache)
        XCTAssertNotNil(app.connectionsUpdatedAt)
        XCTAssertEqual(
            cache.loadConnections()?.connections.map(\.pair), ["pair1"],
            "the fetch must have been written to the cache"
        )
    }

    /// And a stale cache must not survive a successful fetch: the file has to
    /// follow the server, including a connection that has gone.
    func testASuccessfulLoadReplacesAStaleCachedList() async {
        seedCache([connection("gone"), connection("pair1")], at: Date(timeIntervalSince1970: 1))
        ConnectionsStubProtocol.serve([connection("pair1")])

        await app.resolveMembership()

        XCTAssertEqual(cache.loadConnections()?.connections.map(\.pair), ["pair1"])
    }

    // MARK: Clearing

    /// Signing out has to forget the list, or the next person to open the app is
    /// shown the last person's connections — offline, with no server to correct it.
    func testSigningOutForgetsTheCachedConnections() async {
        seedCache([connection("pair1")], at: Date())
        ConnectionsStubProtocol.serve([connection("pair1")])
        await app.resolveMembership()
        XCTAssertNotNil(cache.loadConnections())

        await app.signOut()

        XCTAssertNil(cache.loadConnections(), "a signed-out device must not keep somebody's connections on disk")
        XCTAssertNil(app.connectionsUpdatedAt)
        XCTAssertFalse(app.connectionsFromCache)
    }

    /// And so must a 401, which is the session going away without anybody asking.
    func testASessionClearingForgetsTheCachedConnections() async {
        seedCache([connection("pair1")], at: Date())

        await app.clearSessionAndReturnToAuth()

        XCTAssertNil(cache.loadConnections())
        XCTAssertNil(app.connectionsUpdatedAt)
    }
}

/// Serves `GET /api/peard/connections`, and can be made to fail instead.
///
/// The endpoint is the only thing here that needs to be real: `AppModel` builds
/// its own `APIClient`, so the session is injected to make the fetch succeed or
/// fail on demand.
final class ConnectionsStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload: String?
    nonisolated(unsafe) private static var failure: Error?

    static func serve(_ connections: [Connection]) {
        lock.lock()
        payload = envelope(connections)
        failure = nil
        lock.unlock()
    }

    static func fail(with error: Error) {
        lock.lock()
        payload = nil
        failure = error
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        payload = nil
        failure = nil
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionsStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func envelope(_ connections: [Connection]) -> String {
        let encoder = JSONEncoder.peard
        let body = (try? encoder.encode(ConnectionList(connections: connections)))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? #"{"connections":[]}"#
        return body
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let failure = Self.failure
        // Anything the launch happens to ask for besides the list (push
        // registration, widget sync) is answered with an empty object, so this
        // stub only ever decides the one question the test is about.
        let body = Self.payload ?? "{}"
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
