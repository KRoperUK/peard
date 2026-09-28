import XCTest
@testable import Peard
import PeardCore

/// A moment logged while the timeline is already loaded (#113).
///
/// The tab outlives a switch to Home, so the first page it loaded was all it
/// showed until a pull to refresh. `refreshNewest` brings the top up to date;
/// these pin that it does, and that somebody who has scrolled a few pages down
/// keeps those pages rather than being dropped back to the first.
@MainActor
final class TimelineLiveRefreshTests: XCTestCase {
    private var model: HistoryModel!

    override func setUp() {
        super.setUp()
        PagedTimelineStubProtocol.reset()
        model = HistoryModel(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8090")!,
                tokenProvider: nil,
                session: PagedTimelineStubProtocol.makeSession()
            ),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil
        )
    }

    override func tearDown() {
        PagedTimelineStubProtocol.reset()
        model = nil
        super.tearDown()
    }

    private static func post(_ id: String, minutesAgo: Int) -> Post {
        Post(
            id: id, pair: "pair1", author: "them", type: .event, eventKind: .beer,
            created: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
        )
    }

    /// Newest first, as the server orders them.
    private static func posts(_ prefix: String, _ range: Range<Int>) -> [Post] {
        range.map { post("\(prefix)\($0)", minutesAgo: 10 + $0) }
    }

    func testANewMomentAppearsAtTheTop() async {
        let old = Self.post("old", minutesAgo: 60)
        PagedTimelineStubProtocol.pages = [1: [old]]
        await model.refreshNewest()
        XCTAssertEqual(model.posts.map(\.id), ["old"])

        let new = Self.post("new", minutesAgo: 0)
        PagedTimelineStubProtocol.pages = [1: [new, old]]
        await model.refreshNewest()

        XCTAssertEqual(model.posts.map(\.id), ["new", "old"])
        XCTAssertEqual(model.totalItems, 2)
    }

    func testPagesAlreadyScrolledIntoAreKept() async {
        let first = Self.posts("p", 0..<30)
        let second = Self.posts("p", 30..<60)
        PagedTimelineStubProtocol.pages = [1: first, 2: second]
        await model.refreshNewest()
        await model.loadMoreIfNeeded()
        XCTAssertEqual(model.posts.count, 60)

        // One new moment pushes p29 off the first page and onto the second.
        let new = Self.post("new", minutesAgo: 0)
        PagedTimelineStubProtocol.pages = [1: [new] + first.dropLast(), 2: [first[29]] + second.dropLast()]
        await model.refreshNewest()

        let ids = model.posts.map(\.id)
        XCTAssertEqual(ids.first, "new")
        XCTAssertEqual(ids.count, 61, "both loaded pages stay, plus the new moment")
        XCTAssertEqual(ids.last, "p59")
        XCTAssertEqual(Set(ids).count, ids.count, "no moment appears twice")
    }

    func testMoreThanAPageOfNewMomentsStartsAgainFromTheTop() async {
        let first = Self.posts("p", 0..<30)
        let second = Self.posts("p", 30..<60)
        PagedTimelineStubProtocol.pages = [1: first, 2: second]
        await model.refreshNewest()
        await model.loadMoreIfNeeded()
        XCTAssertEqual(model.posts.count, 60)

        let flood = Self.posts("n", 0..<30).map {
            Post(id: $0.id, pair: "pair1", author: "them", type: .event, eventKind: .coffee, created: Date())
        }
        PagedTimelineStubProtocol.pages = [1: flood, 2: first]
        await model.refreshNewest()

        XCTAssertEqual(model.posts.map(\.id), flood.map(\.id))
        XCTAssertTrue(model.hasMore, "the rest is a scroll away again")
    }
}

/// Answers the posts collection by page number from `pages`, with a total that
/// says whether there is another page.
final class PagedTimelineStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: [Int: [Post]] = [:]

    static var pages: [Int: [Post]] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagedTimelineStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        pages = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        let json: String
        if url.path.contains("reactions") {
            json = #"{"items":[]}"#
        } else {
            let all = Self.pages
            let items = all[page] ?? []
            let totalPages = max(all.keys.max() ?? 1, 1)
            let totalItems = all.values.reduce(0) { $0 + $1.count }
            json = #"{"page":\#(page),"perPage":30,"totalItems":\#(totalItems),"totalPages":\#(totalPages),"items":\#(Self.encode(items))}"#
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func encode(_ posts: [Post]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            try container.encode(formatter.string(from: date))
        }
        return (try? encoder.encode(posts)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
