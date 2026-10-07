import XCTest
@testable import Peard
import PeardCore
import SwiftUI

/// The water streak on the Tallies recap (#323).
///
/// The streak is counted by the server against the target this phone sends, and
/// the row is shown only while water is tracked in the connection. What needs the
/// app target is that wiring: the model sends the connection's own recommended
/// amount, keeps the answer, and the section shows or hides the row accordingly.
/// Each test has a shared store of its own, so none starts from what another saved.
@MainActor
final class RecapWaterStreakFlowTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queueURL: URL!
    private var suiteName: String!
    private var sessionStore: KeychainSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        RecapStubProtocol.reset()
        queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-recapwater-\(UUID().uuidString).json")
        suiteName = "peard-recapwater-\(UUID().uuidString)"
        let shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        shared.hasRequestedNotificationAuthorization = true
        sessionStore = KeychainSessionStore(service: "peard-recapwater-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")

        app = AppModel(
            config: PeardConfig(serverURL: URL(string: "http://stub.peard.test")!, googleClientID: ""),
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: SendQueue(store: FilePendingSendStore(url: queueURL)),
            momentInbox: MomentInbox(url: queueURL.appendingPathExtension("inbox")),
            connectionCache: FileConnectionCache(url: queueURL.appendingPathExtension("cache")),
            session: RecapStubProtocol.makeSession()
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
        RecapStubProtocol.reset()
        model = nil
        app = nil
        try await super.tearDown()
    }

    private func section(_ recap: MomentRecap, waterEnabled: Bool = true) -> RecapSection {
        RecapSection(recap: recap, mineLabel: "You", othersLabel: "Ari", waterEnabled: waterEnabled)
    }

    private func recap(water: MomentRecap.Streak?) -> MomentRecap {
        MomentRecap(total: 4, mine: 3, others: 1, streak: .init(current: 2, best: 2), waterStreak: water)
    }

    // MARK: What is asked

    func testTheRecapIsAskedAgainstThisConnectionsOwnTarget() async {
        model.updateWaterConfig { $0.setRecommended(2500) }
        RecapStubProtocol.reset()
        RecapStubProtocol.body = #"{"total":1}"#

        await model.refreshRecap()

        XCTAssertEqual(RecapStubProtocol.lastRecapQuery("water_target"), "2500")
    }

    func testTheDefaultTargetIsSentWhenNothingWasChanged() async {
        RecapStubProtocol.body = #"{"total":1}"#

        await model.refreshRecap()

        XCTAssertEqual(RecapStubProtocol.lastRecapQuery("water_target"), String(WaterAmount.defaultRecommended))
    }

    func testChangingTheTargetAsksTheServerAgain() async {
        RecapStubProtocol.body = #"{"total":1}"#
        await model.refreshRecap()
        let before = RecapStubProtocol.recapRequests

        model.updateWaterConfig { $0.setRecommended(3000) }
        for _ in 0..<50 where RecapStubProtocol.recapRequests == before {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(RecapStubProtocol.recapRequests, before + 1)
        XCTAssertEqual(RecapStubProtocol.lastRecapQuery("water_target"), "3000")
    }

    func testChangingSomethingElseDoesNotAskAgain() async {
        RecapStubProtocol.body = #"{"total":1}"#
        await model.refreshRecap()
        let before = RecapStubProtocol.recapRequests

        model.updateWaterConfig { $0.addPreset(250) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(RecapStubProtocol.recapRequests, before)
    }

    func testTheAnswerIsKept() async {
        RecapStubProtocol.body = #"{"total":4,"streak":{"current":2,"best":2},"water_streak":{"current":5,"best":7}}"#

        await model.refreshRecap()

        XCTAssertEqual(model.recap?.waterStreak, MomentRecap.Streak(current: 5, best: 7))
    }

    // MARK: What is shown

    func testALiveStreakShowsTheRow() {
        XCTAssertTrue(section(recap(water: .init(current: 5, best: 5))).showsWaterStreak)
    }

    func testABrokenStreakWithAWorthwhileBestStillShowsTheRow() {
        XCTAssertTrue(section(recap(water: .init(current: 0, best: 4))).showsWaterStreak)
    }

    func testNoRunToMentionHidesTheRow() {
        XCTAssertFalse(section(recap(water: .init(current: 0, best: 0))).showsWaterStreak)
        XCTAssertFalse(section(recap(water: .init(current: 0, best: 1))).showsWaterStreak)
    }

    func testAnOldServerHidesTheRow() {
        XCTAssertFalse(section(recap(water: nil)).showsWaterStreak)
    }

    /// Turning water off hides the row however long the run was.
    func testWaterBeingOffHidesTheRow() {
        let long = recap(water: .init(current: 9, best: 9))

        XCTAssertFalse(section(long, waterEnabled: false).showsWaterStreak)
        XCTAssertTrue(section(long, waterEnabled: true).showsWaterStreak)
    }

    func testTheRowReadsPerConnection() {
        XCTAssertEqual(RecapSection.waterStreakText(.init(current: 5, best: 5)), "5 days hitting your water goal")
        XCTAssertEqual(RecapSection.waterStreakText(.init(current: 1, best: 3)), "1 day hitting your water goal")
        XCTAssertEqual(
            RecapSection.waterStreakText(.init(current: 0, best: 4)),
            "Water streak ended — best was 4 days hitting your goal"
        )
    }

    func testTheSectionRendersWithTheRow() {
        let view = Form { section(recap(water: .init(current: 5, best: 7))) }
        XCTAssertNotNil(ImageRenderer(content: view.frame(width: 360, height: 600)).uiImage)
    }
}

/// Answers the recap route with `body` and records what it was asked.
final class RecapStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recapURLs: [URL] = []
    nonisolated(unsafe) private static var targetBodies: [[String: Any]] = []
    nonisolated(unsafe) static var body = "{}"
    /// What the per-person target route answers with (#335).
    nonisolated(unsafe) static var targetStatus = 200

    static func reset() {
        lock.lock()
        recapURLs = []
        targetBodies = []
        body = "{}"
        targetStatus = 200
        lock.unlock()
    }

    /// The bodies POSTed to `/api/peard/water/target`, oldest first.
    static var targetPosts: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return targetBodies
    }

    static var recapRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return recapURLs.count
    }

    static func lastRecapQuery(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = recapURLs.last else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecapStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var payload = "{}"
        var status = 200
        if let url = request.url, url.path == "/api/peard/recap" {
            Self.lock.lock()
            Self.recapURLs.append(url)
            payload = Self.body
            Self.lock.unlock()
        } else if let url = request.url, url.path == "/api/peard/water/target" {
            let sent = Self.readBody(of: request)
            Self.lock.lock()
            if let json = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] {
                Self.targetBodies.append(json)
            }
            status = Self.targetStatus
            Self.lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A request's body, which URLSession hands a protocol as a stream.
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
