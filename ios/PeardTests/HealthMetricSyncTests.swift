import XCTest
@testable import Peard
import PeardCore

/// Apple Health totals reaching the connection (#411).
///
/// The Health store is replaced by a stub, so what is tested is the plumbing:
/// which metrics sync, that the day is the member's own calendar day, that an
/// unchanged figure is not re-sent, and that a device without Health (or a
/// denied permission) simply does nothing.
@MainActor
final class HealthMetricSyncTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var health: StubHealthMetrics!
    private var queueURL: URL!
    private var suiteName: String!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        HealthStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-health-\(UUID().uuidString).json")
        suiteName = "peard-health-\(UUID().uuidString)"
        let shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        shared.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-health-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: HealthStubProtocol.makeSession()
        )
        await app.attachSendQueue()
        health = StubHealthMetrics()
        model = HomeModel(app: app, pairID: "pair1", health: health)
    }

    override func tearDown() async throws {
        for suffix in ["", ".inbox", ".cache"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: queueURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        HealthStubProtocol.reset()
        model = nil
        app = nil
        health = nil
        try await super.tearDown()
    }

    /// A fixed clock, in UTC, so the day assertion never depends on the machine.
    private var noon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The total is pushed as the member's own day, in the metric's canonical
    /// unit, through the upsert route.
    func testATrackedMetricIsPushedForToday() async {
        health.totals = [MetricCatalogue.steps.slug: 4321]
        model.setMetricGoal(8000, definition: MetricCatalogue.steps)

        await model.syncHealthMetrics(now: noon, calendar: utc)

        let sent = HealthStubProtocol.dayPuts
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["pair"] as? String, "pair1")
        XCTAssertEqual(sent.first?["metric"] as? String, "steps")
        XCTAssertEqual(sent.first?["day"] as? String, "2026-10-22")
        XCTAssertEqual(sent.first?["amount"] as? Int, 4321)
        XCTAssertEqual(sent.first?["source"] as? String, "health")
    }

    /// A refresh every few minutes must not write the same figure again.
    func testAnUnchangedTotalIsNotSentTwice() async {
        health.totals = [MetricCatalogue.steps.slug: 4321]
        model.setMetricGoal(8000, definition: MetricCatalogue.steps)

        await model.syncHealthMetrics(now: noon, calendar: utc)
        await model.syncHealthMetrics(now: noon.addingTimeInterval(60), calendar: utc)

        XCTAssertEqual(HealthStubProtocol.dayPuts.count, 1)
    }

    /// A new day is a new figure even when the total happens to match.
    func testANewDayIsSentAgain() async {
        health.totals = [MetricCatalogue.steps.slug: 4321]
        model.setMetricGoal(8000, definition: MetricCatalogue.steps)

        await model.syncHealthMetrics(now: noon, calendar: utc)
        let tomorrow = utc.date(byAdding: .day, value: 1, to: noon)!
        await model.syncHealthMetrics(now: tomorrow, calendar: utc)

        XCTAssertEqual(HealthStubProtocol.dayPuts.count, 2)
        XCTAssertEqual(HealthStubProtocol.dayPuts.last?["day"] as? String, "2026-10-23")
    }

    /// A metric nobody tracks has no goal, so nothing is read or sent.
    func testAnUntrackedMetricIsNotSent() async {
        health.totals = [MetricCatalogue.steps.slug: 4321]

        await model.syncHealthMetrics(now: noon, calendar: utc)

        XCTAssertTrue(HealthStubProtocol.dayPuts.isEmpty)
    }

    /// A device without Health sends nothing, and that is not an error.
    func testADisabledProviderDoesNothing() async {
        let disabled = HomeModel(app: app, pairID: "pair1", health: DisabledHealthMetrics())
        disabled.setMetricGoal(8000, definition: MetricCatalogue.steps)

        await disabled.syncHealthMetrics(now: noon, calendar: utc)

        XCTAssertTrue(HealthStubProtocol.dayPuts.isEmpty)
    }

    /// The day is `yyyy-MM-dd` from calendar components, so a locale cannot
    /// reorder or translate it.
    func testTheDayIsAnISODate() {
        XCTAssertEqual(HomeModel.healthDay(noon, calendar: utc), "2026-10-22")
    }

    /// Turning a metric on asks for read access, once, for that metric.
    func testEnablingATrackedMetricAsksForAccess() async {
        await model.enableHealthSync(for: MetricCatalogue.steps)

        XCTAssertEqual(health.authorised, [MetricCatalogue.steps.slug])
    }
}

/// A Health store stand-in: what it says today is what the test sets.
final class StubHealthMetrics: HealthMetricsProviding {
    var totals: [EventKind: Int] = [:]
    var authorised: [EventKind] = []
    var isAvailable = true

    func supports(_ metric: EventKind) -> Bool {
        metric == MetricCatalogue.steps.slug || metric == MetricCatalogue.exercise.slug
    }

    func requestAuthorization(for metrics: [EventKind]) async -> Bool {
        authorised.append(contentsOf: metrics.filter(supports))
        return true
    }

    func todayTotals(for metrics: [EventKind], now: Date, calendar: Calendar) async -> [EventKind: Int] {
        totals.filter { metrics.contains($0.key) }
    }
}

/// Answers every request, recording the per-day upserts.
final class HealthStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var puts: [[String: Any]] = []

    static func reset() {
        lock.lock()
        puts = []
        lock.unlock()
    }

    static var dayPuts: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return puts
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url, url.path == "/api/peard/metric/day", request.httpMethod == "PUT" {
            let body = Self.readBody(of: request)
            if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                Self.lock.lock()
                Self.puts.append(json)
                Self.lock.unlock()
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func stopLoading() {}
}
