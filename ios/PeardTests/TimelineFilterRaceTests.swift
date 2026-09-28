import XCTest
@testable import Peard
import PeardCore

/// A page that belongs to a filter the timeline has already moved on from.
///
/// The bug this pins (#59): `apply(_:)` empties the timeline and fetches page
/// one for the new filter, but a request made under the old one — a scroll to
/// the bottom, or the previous search still in flight — could land afterwards.
/// Its rows were appended to the new results and its `hasMore` and
/// `totalItems` overwrote the new query's, so a search for "fresh" could show
/// last week's "stale" moments underneath and a count describing neither.
@MainActor
final class TimelineFilterRaceTests: XCTestCase {
    private var model: HistoryModel!

    private static let stale = Post(
        id: "stale", pair: "pair1", author: "them", type: .event, eventKind: .beer, created: Date()
    )
    private static let fresh = Post(
        id: "fresh", pair: "pair1", author: "them", type: .event, eventKind: .coffee, created: Date()
    )

    override func setUp() {
        super.setUp()
        GatedTimelineStubProtocol.reset()
        model = HistoryModel(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8090")!,
                tokenProvider: nil,
                session: GatedTimelineStubProtocol.makeSession()
            ),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil
        )
    }

    override func tearDown() {
        GatedTimelineStubProtocol.reset()
        model = nil
        super.tearDown()
    }

    /// Search for "stale", then change it to "fresh" before the first answer
    /// arrives. Only the second answer may reach the screen, whichever lands last.
    func testAPageForAReplacedFilterIsDropped() async throws {
        GatedTimelineStubProtocol.hold(search: "stale", answer: [Self.stale, Self.fresh], totalItems: 40)
        GatedTimelineStubProtocol.answer(search: "fresh", with: [Self.fresh], totalItems: 1)

        let first = Task { await model.apply(TimelineFilter(search: "stale")) }
        try await waitUntil { GatedTimelineStubProtocol.isHolding }

        await model.apply(TimelineFilter(search: "fresh"))
        XCTAssertEqual(model.posts.map(\.id), ["fresh"])

        GatedTimelineStubProtocol.release()
        await first.value

        XCTAssertEqual(model.posts.map(\.id), ["fresh"], "the old search's rows must not be appended")
        XCTAssertEqual(model.totalItems, 1, "nor its count kept")
        XCTAssertFalse(model.hasMore, "nor its idea of whether there is more")
        XCTAssertEqual(model.filter.search, "fresh")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for the held request")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Answers the posts collection by the search in its filter, and can hold one
/// search's answer back until the test says so — which is how two requests are
/// made to land in the opposite order to the one they were sent in.
final class GatedTimelineStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: String] = [:]
    nonisolated(unsafe) private static var heldSearch: String?
    nonisolated(unsafe) private static var held: [GatedTimelineStubProtocol] = []

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedTimelineStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func answer(search: String, with posts: [Post], totalItems: Int) {
        lock.lock()
        answers[search] = envelope(posts, totalItems: totalItems)
        lock.unlock()
    }

    static func hold(search: String, answer posts: [Post], totalItems: Int) {
        answer(search: search, with: posts, totalItems: totalItems)
        lock.lock()
        heldSearch = search
        lock.unlock()
    }

    static var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !held.isEmpty
    }

    static func release() {
        lock.lock()
        let waiting = held
        held = []
        heldSearch = nil
        lock.unlock()
        waiting.forEach { $0.respond() }
    }

    static func reset() {
        lock.lock()
        answers = [:]
        heldSearch = nil
        held = []
        lock.unlock()
    }

    private static func envelope(_ posts: [Post], totalItems: Int) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            try container.encode(formatter.string(from: date))
        }
        let body = (try? encoder.encode(posts)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let totalPages = totalItems > posts.count ? 2 : 1
        return #"{"page":1,"perPage":30,"totalItems":\#(totalItems),"totalPages":\#(totalPages),"items":\#(body)}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var search: String? {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "filter" }?.value ?? ""
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.answers.keys.first { query.contains($0) }
    }

    override func startLoading() {
        let search = self.search
        Self.lock.lock()
        let shouldHold = search != nil && search == Self.heldSearch
        if shouldHold {
            Self.held.append(self)
        }
        Self.lock.unlock()
        if !shouldHold {
            respond()
        }
    }

    private func respond() {
        let path = request.url?.path ?? ""
        let search = self.search
        Self.lock.lock()
        // Reactions are not what this is about; an empty answer keeps them quiet.
        let empty = #"{"items":[]}"#
        let json = path.contains("reactions") ? empty : search.flatMap { Self.answers[$0] } ?? empty
        Self.lock.unlock()
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
