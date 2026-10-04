import XCTest
@testable import Peard
import PeardCore

/// A reply on the timeline says which photo it answers, and still reads when
/// that photo is not to hand (issue #304).
@MainActor
final class PhotoReplyTimelineTests: XCTestCase {
    private var model: HistoryModel!

    private static let photo = Post(
        id: "photo1", pair: "pair1", author: "me", type: .photo, media: "p.jpg", created: Date()
    )
    private static let reply = Post(
        id: "reply1", pair: "pair1", author: "them", type: .note, note: "lovely",
        created: Date(), replyTo: "photo1"
    )

    override func setUp() {
        super.setUp()
        TimelineStubProtocol.reset()
        model = HistoryModel(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8090")!,
                tokenProvider: nil,
                session: TimelineStubProtocol.makeSession()
            ),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: nil
        )
    }

    override func tearDown() {
        TimelineStubProtocol.reset()
        model = nil
        super.tearDown()
    }

    func testAReplyOnTheSamePageFindsItsPhoto() async {
        TimelineStubProtocol.route(posts: [Self.reply, Self.photo], reactions: [])

        await model.loadFirstPage()

        XCTAssertEqual(model.original(for: Self.reply)?.id, "photo1")
        XCTAssertEqual(model.replyTitle(for: Self.reply), "replying to your photo")
    }

    /// The stub answers the follow-up fetch without the photo, which is what a
    /// photo deleted in the meantime looks like.
    func testAReplyWhosePhotoCannotBeFoundStillReads() async {
        TimelineStubProtocol.route(posts: [Self.reply], reactions: [])

        await model.loadFirstPage()

        XCTAssertNil(model.original(for: Self.reply))
        XCTAssertEqual(model.replyTitle(for: Self.reply), "replying to a photo")
    }

    func testAPostThatAnswersNothingHasNoPhoto() async {
        TimelineStubProtocol.route(posts: [Self.photo], reactions: [])

        await model.loadFirstPage()

        XCTAssertNil(model.original(for: Self.photo))
    }

    func testSomebodyElsesPhotoIsNamed() {
        let theirs = Post(id: "p", pair: "pair1", author: "ada", type: .photo, media: "p.jpg", created: Date())

        XCTAssertEqual(
            ReplyChip.title(for: theirs, signedInUserID: "me") { _ in "Ada" },
            "replying to Ada's photo"
        )
    }
}
