import XCTest
@testable import PeardCore

/// Fetching reactions for a whole page of the timeline.
///
/// One request per post would be thirty requests per page. One request for all
/// thirty would risk PocketBase's 500-row `perPage` ceiling, and the overflow
/// would look exactly like "nobody reacted to the older ones" — so this is
/// chunked, and the chunk size is the thing worth pinning down.
final class BatchedReactionsTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    func testOnePageOfPostsIsOneRequest() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        _ = try await client.reactions(postIDs: ["a", "b", "c"])

        let items = try queryItems()
        XCTAssertEqual(items["filter"], #"(post = "a" || post = "b" || post = "c")"#)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/collections/reactions/records")
    }

    /// Ten posts of the maximum twelve members, each having used all three
    /// kinds, is 360 rows — under the 500 ceiling with room to spare. Eleven
    /// would not be, so the chunk boundary is asserted rather than assumed.
    func testPostsAreChunkedInTens() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)
        let ids = (1...25).map { "post\($0)" }

        _ = try await client.reactions(postIDs: ids)

        XCTAssertEqual(StubURLProtocol.requestCount, 3, "25 posts is three requests of at most ten")
    }

    func testNoPostsIsNoRequest() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        let reactions = try await client.reactions(postIDs: [])

        XCTAssertTrue(reactions.isEmpty)
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "an empty page must not hit the network")
    }

    func testResultsFromEveryChunkAreReturned() async throws {
        StubURLProtocol.respond(json: #"""
        {"items":[{"id":"r1","post":"post1","user":"u1","kind":"heart"}]}
        """#)

        let reactions = try await client.reactions(postIDs: (1...15).map { "post\($0)" })

        XCTAssertEqual(reactions.count, 2, "both chunks' results, not just the last one's")
    }

    /// A post id is server-generated and cannot contain a quote, but the filter
    /// builder is what guarantees that stays true if one ever does.
    func testIdsAreEscapedIntoTheFilter() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        _ = try await client.reactions(postIDs: [#"a"b"#])

        XCTAssertEqual(try queryItems()["filter"], #"post = "a\"b""#)
    }

    private func queryItems() throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
