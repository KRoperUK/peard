import XCTest
@testable import PeardCore

/// #367 — the devices screen's two calls: list the caller's widget tokens and
/// revoke one by id.
final class WidgetTokenListTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession(),
            boundaryFactory: { "TestBoundary" }
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    private let listJSON = #"""
    {"tokens":[
      {"id":"t1","label":"ios-widget","created":"2026-10-01 08:00:00.000Z","expires":"2026-10-31 08:00:00.000Z"},
      {"id":"t2","label":"ios-widget","created":"2026-09-01 08:00:00.000Z","expires":null}
    ]}
    """#

    func testListDecodesAndNeverNeedsASecret() async throws {
        StubURLProtocol.respond(json: listJSON)

        let tokens = try await client.widgetTokens()

        XCTAssertEqual(tokens.map(\.id), ["t1", "t2"])
        XCTAssertNotNil(tokens[0].expires)
        XCTAssertNil(tokens[1].expires)
        XCTAssertFalse(tokens.contains { $0.isCurrentDevice })
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/peard/widget/tokens")
    }

    func testListMarksOnlyThisDevicesToken() async throws {
        StubURLProtocol.respond(json: listJSON)

        let tokens = try await client.widgetTokens(currentTokenID: "t2")

        XCTAssertEqual(tokens.filter(\.isCurrentDevice).map(\.id), ["t2"])
    }

    func testRevokeByIDPostsTheID() async throws {
        StubURLProtocol.respond(json: #"{"revoked":true}"#)

        try await client.revokeWidgetToken(id: "t1")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/peard/widget/revoke")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["id": "t1"])
    }
}
