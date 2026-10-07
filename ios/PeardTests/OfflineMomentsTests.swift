import XCTest
@testable import Peard
import PeardCore

/// What the Home grid offers when the custom-moment fetch cannot be made (#313).
///
/// The bug this guards: offline, a connection's published moments vanished and
/// the grid dropped to the built-ins only. So two things are kept apart — a
/// failed fetch with a cache behind it keeps the custom moments, and a
/// successful fetch writes them so the next offline launch has them.
@MainActor
final class OfflineMomentsTests: XCTestCase {
    private var app: AppModel!
    private var queueURL: URL!
    private var suiteName: String!
    private var shared: SharedStore!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        MomentKindsStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-moments-\(UUID().uuidString).json")
        suiteName = "peard-moments-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        sessionStore = KeychainSessionStore(service: "peard-moments-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: MomentKindsStubProtocol.makeSession()
        )
    }

    override func tearDown() async throws {
        for suffix in ["", ".cache"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: queueURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        MomentKindsStubProtocol.reset()
        sessionStore = nil
        shared = nil
        app = nil
        queueURL = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func kind(_ slug: String) -> MomentKind {
        MomentKind(id: "id-\(slug)", pair: "pair1", slug: EventKind(rawValue: slug), emoji: "🫶", label: slug.capitalized)
    }

    /// The write half: a fetched list has to reach the cache, or the next offline
    /// launch has nothing to fall back on — a failure that is invisible until then.
    func testASuccessfulRefreshCachesTheMoments() async {
        MomentKindsStubProtocol.serve([kind("coffee"), kind("walk")])
        let model = HomeModel(app: app, pairID: "pair1")

        await model.refreshCustomKinds()

        XCTAssertEqual(model.customKinds.map { $0.slug.rawValue }, ["coffee", "walk"])
        XCTAssertEqual(
            shared.cachedMomentKinds(forConnection: "pair1").map { $0.slug.rawValue }, ["coffee", "walk"],
            "the fetch must have been written to the cache"
        )
    }

    /// The read half, and the heart of the slice: offline, the custom moments
    /// stay rather than dropping to the built-ins.
    func testAFailedRefreshFallsBackToTheCachedMoments() async {
        shared.setCachedMomentKinds([kind("coffee")], forConnection: "pair1")
        MomentKindsStubProtocol.fail(with: URLError(.notConnectedToInternet))
        let model = HomeModel(app: app, pairID: "pair1")

        await model.refreshCustomKinds()

        XCTAssertEqual(model.customKinds.map { $0.slug.rawValue }, ["coffee"])
    }

    /// A first-ever offline launch, with nothing cached, is the built-ins only —
    /// there is nothing to restore, and that is not an error worth a banner.
    func testAFailedRefreshWithNoCacheLeavesNoCustomMoments() async {
        MomentKindsStubProtocol.fail(with: URLError(.notConnectedToInternet))
        let model = HomeModel(app: app, pairID: "pair1")

        await model.refreshCustomKinds()

        XCTAssertTrue(model.customKinds.isEmpty)
    }
}

/// Serves `GET /api/collections/moment_kinds/records`, and can be made to fail.
///
/// `AppModel` builds its own `APIClient`, so the session is injected to make the
/// one request this suite cares about succeed or fail on demand; anything else a
/// stray call asks for is answered with an empty object.
final class MomentKindsStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload: String?
    nonisolated(unsafe) private static var failure: Error?

    static func serve(_ kinds: [MomentKind]) {
        lock.lock()
        payload = (try? JSONEncoder.peard.encode(RecordList(items: kinds)))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? #"{"items":[]}"#
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
        configuration.protocolClasses = [MomentKindsStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isMomentKinds = request.url?.path.contains("moment_kinds") ?? false
        Self.lock.lock()
        let failure = Self.failure
        let body = Self.payload ?? "{}"
        Self.lock.unlock()

        if isMomentKinds, let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isMomentKinds ? body : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
