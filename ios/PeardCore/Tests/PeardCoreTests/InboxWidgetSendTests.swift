import XCTest
@testable import PeardCore

/// The watch's offline queue, sent later through the widget route.
final class InboxWidgetSendTests: XCTestCase {
    private var inbox: MomentInbox!
    private var directory: URL!
    private var api: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = MomentInbox(url: directory.appendingPathComponent("inbox.json"))
        api = APIClient(baseURL: URL(string: "http://127.0.0.1:8090")!, session: StubURLProtocol.makeSession())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func queue(_ id: String, _ kind: EventKind = .beer, at date: Date = Date()) {
        inbox.append(InboxedMoment(id: id, pairID: "pair1", kind: kind, emoji: "🍺", label: "Beer", queuedAt: date))
    }

    private let ok = #"{"id":"p1","pair":"pair1","kind":"beer"}"#

    func testWaitingMomentsAreSentWithTheirIDAndTapTime() async throws {
        let tapped = Date(timeIntervalSince1970: 1_790_000_000)
        queue("m1", at: tapped)
        StubURLProtocol.respond(json: ok)

        let remaining = await inbox.sendThroughWidgetRoute(using: api, token: "widget-token")

        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(inbox.load().isEmpty)
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(fields["client_id"], "m1", "a resend must be refusable as a duplicate")
        XCTAssertEqual(fields["happened_at"], Rewind.wireString(tapped))
        XCTAssertEqual(fields["pair"], "pair1")
        XCTAssertEqual(fields["token"], "widget-token")
    }

    /// Still offline: nothing is lost, and the rest are not tried.
    func testARetryableFailureKeepsEverythingAndStops() async {
        queue("m1")
        queue("m2", .coffee)
        StubURLProtocol.failWith(URLError(.notConnectedToInternet))

        let remaining = await inbox.sendThroughWidgetRoute(using: api, token: "t")

        XCTAssertEqual(remaining, 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// Refused outright — a moment the connection no longer has, or one that
    /// already arrived — retrying cannot help, so it goes.
    func testARefusedMomentIsDropped() async {
        queue("m1")
        queue("m2", .coffee)
        StubURLProtocol.respond(json: #"{"message":"that moment isn't available"}"#, status: 400)

        let remaining = await inbox.sendThroughWidgetRoute(using: api, token: "t")

        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    /// Photos and notes are the phone's to send; this leaves them be.
    func testPhotosAndNotesAreLeftAlone() async {
        inbox.append(InboxedMoment(id: "note1", pairID: "pair1", kind: EventKind(rawValue: ""), emoji: "💬",
                                   label: "Reply", note: "hi", postType: .note))
        StubURLProtocol.respond(json: ok)

        let remaining = await inbox.sendThroughWidgetRoute(using: api, token: "t")

        XCTAssertEqual(remaining, 0, "not counted as the watch's to send")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(inbox.load().map(\.id), ["note1"])
    }
}
