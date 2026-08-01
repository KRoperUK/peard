import XCTest
@testable import PeardCore

/// Editing a moment after it has been logged: what the client sends, and how it
/// decides whether to say "edited".
final class MomentEditTests: XCTestCase {
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

    // MARK: The request

    func testEditingANoteSendsOnlyTheNote() async throws {
        StubURLProtocol.respond(json: #"{"ok":true}"#)

        try await client.editMoment(postID: "p1", note: "at the other pub")

        let body = try lastBody()
        XCTAssertEqual(body["post"] as? String, "p1")
        XCTAssertEqual(body["note"] as? String, "at the other pub")
        XCTAssertNil(body["event_kind"], "a kind that was not changed must not be sent")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/peard/posts/edit")
    }

    func testEditingAKindSendsOnlyTheKind() async throws {
        StubURLProtocol.respond(json: #"{"ok":true}"#)

        try await client.editMoment(postID: "p1", kind: .coffee)

        let body = try lastBody()
        XCTAssertEqual(body["event_kind"] as? String, "coffee")
        XCTAssertNil(body["note"], "a note that was not changed must not be sent")
    }

    /// Taking the words back has to be expressible. `nil` means "leave it
    /// alone", so clearing is `.some("")` — the doubled optional exists for
    /// exactly this, and it would be easy to collapse by accident.
    func testANoteCanBeClearedRatherThanLeftAlone() async throws {
        StubURLProtocol.respond(json: #"{"ok":true}"#)

        try await client.editMoment(postID: "p1", note: .some(""))

        let body = try lastBody()
        XCTAssertEqual(body["note"] as? String, "")
    }

    func testDeletingUsesTheCollectionEndpoint() async throws {
        StubURLProtocol.respond(json: "", status: 204)

        try await client.deleteMoment(postID: "p1")

        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/collections/posts/records/p1")
    }

    // MARK: isEdited

    func testAFreshMomentIsNotEdited() {
        let created = Date()
        let post = post(created: created, updated: created)

        XCTAssertFalse(post.isEdited)
    }

    /// Both stamps are written in the same breath at creation, to the
    /// millisecond, so a create landing either side of a tick must not read as
    /// an edit nobody made.
    func testAMomentSavedAMomentApartIsNotEdited() {
        let created = Date()

        XCTAssertFalse(post(created: created, updated: created.addingTimeInterval(0.4)).isEdited)
        XCTAssertFalse(post(created: created, updated: created.addingTimeInterval(1.9)).isEdited)
    }

    func testAMomentChangedLaterIsEdited() {
        let created = Date()

        XCTAssertTrue(post(created: created, updated: created.addingTimeInterval(30)).isEdited)
    }

    /// A record predating the server's timestamps has no `created` to compare
    /// against, and must not be labelled on the strength of a sentinel.
    func testAnUndatedMomentIsNeverEdited() {
        let post = Post(id: "p1", pair: "pair1", author: "u1", type: .event, created: .distantPast)

        XCTAssertFalse(post.isEdited)
    }

    // MARK: Decoding

    func testUpdatedIsDecoded() throws {
        let json = #"""
        {"id":"p1","pair":"pair1","author":"u1","type":"event","event_kind":"beer","note":"",
         "created":"2026-07-28 21:30:15.250Z","updated":"2026-07-29 09:00:00.000Z"}
        """#
        let post = try JSONDecoder.peard.decode(Post.self, from: Data(json.utf8))

        XCTAssertTrue(post.isEdited)
        XCTAssertGreaterThan(post.updated, post.created)
    }

    /// A server predating the timestamps migration sends no `updated`. That must
    /// not fail the decode, and must not read as an edit in 1970 — which is what
    /// a `distantPast` default would have produced.
    func testAMissingUpdatedFallsBackToCreated() throws {
        let json = #"""
        {"id":"p1","pair":"pair1","author":"u1","type":"event","event_kind":"beer",
         "created":"2026-07-28 21:30:15.250Z"}
        """#
        let post = try JSONDecoder.peard.decode(Post.self, from: Data(json.utf8))

        XCTAssertEqual(post.updated, post.created)
        XCTAssertFalse(post.isEdited)
    }

    // MARK: Helpers

    private func post(created: Date, updated: Date) -> Post {
        Post(id: "p1", pair: "pair1", author: "u1", type: .event, eventKind: .beer, created: created, updated: updated)
    }

    private func lastBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
