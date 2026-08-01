import XCTest
@testable import PeardCore

/// The two sizes a shared photo is fetched at, and the difference between them.
///
/// It matters which one a screen asks for: these are camera photos, several
/// megabytes each, and the timeline draws them 36 points across.
final class MediaPathTests: XCTestCase {
    func testTheThumbnailPathAsksForAThumbnail() {
        let path = photo(media: "beach.jpg").mediaThumbnailPath()

        XCTAssertEqual(path, "/api/files/posts/p1/beach.jpg?thumb=512x512")
    }

    func testTheFullSizePathAsksForNoThumbnail() {
        let path = photo(media: "beach.jpg").mediaPath()

        XCTAssertEqual(path, "/api/files/posts/p1/beach.jpg")
        XCTAssertFalse(path?.contains("thumb") ?? true, "the viewer wants the photo, not a 512-point copy of it")
    }

    /// PocketBase keeps the uploaded filename, which can be anything a camera
    /// roll or a share sheet produced. An unescaped space breaks the URL, and
    /// the failure looks like a missing photo rather than a bad path.
    func testAwkwardFilenamesAreEscaped() {
        let post = photo(media: "holiday photo (1).jpg")

        XCTAssertEqual(post.mediaPath(), "/api/files/posts/p1/holiday%20photo%20(1).jpg")
        XCTAssertEqual(post.mediaThumbnailPath(), "/api/files/posts/p1/holiday%20photo%20(1).jpg?thumb=512x512")
    }

    func testAPostWithNoMediaHasNeitherPath() {
        let post = Post(id: "p1", pair: "pair1", author: "u1", type: .event, eventKind: .beer, created: Date())

        XCTAssertNil(post.mediaPath())
        XCTAssertNil(post.mediaThumbnailPath())
        XCTAssertFalse(post.hasMedia)
    }

    /// PocketBase sends `""` rather than omitting the field for a post with no
    /// attachment, which is not the same as having one called "".
    func testAnEmptyFilenameIsNotAPhoto() {
        let post = photo(media: "")

        XCTAssertNil(post.mediaPath())
        XCTAssertNil(post.mediaThumbnailPath())
    }

    private func photo(media: String) -> Post {
        Post(id: "p1", pair: "pair1", author: "u1", type: .photo, media: media, created: Date())
    }
}
