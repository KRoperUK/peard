import ActivityKit
import PeardCore
import XCTest
@testable import Peard

/// The pieces of the photo-drop Live Activity that can be checked without a
/// push: the wire format the server writes, and the photo cache the
/// notification service extension fills for it.
final class PhotoDropTests: XCTestCase {
    /// Exactly what `photoDropPayload` puts in `content-state`. A key renamed on
    /// either side fails to decode on the phone, silently, and the activity
    /// never updates.
    func testTheServersContentStateDecodes() throws {
        let json = #"{"postID":"abc123def456ghi","authorName":"Ada","caption":"look","count":3,"updatedAt":1790000000}"#

        let state = try JSONDecoder().decode(PhotoDropAttributes.ContentState.self, from: Data(json.utf8))

        XCTAssertEqual(state.postID, "abc123def456ghi")
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.updated, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheServersAttributesDecode() throws {
        let json = #"{"pairID":"pair1","title":"Flatmates"}"#
        let attributes = try JSONDecoder().decode(PhotoDropAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(attributes.title, "Flatmates")
    }

    /// The extension keeps its own copy of the cache's name and place, because
    /// it does not link PeardCore. These have to agree or the activity looks in
    /// the wrong place.
    func testTheExtensionAndTheActivityAgreeWhereThePhotoGoes() {
        XCTAssertEqual(NotificationService.appGroup, SharedStore.appGroupIdentifier)
        XCTAssertEqual(NotificationService.cacheDirectoryName, PhotoDropCache.directoryName)
        for id in ["abc123def456ghi", "../../etc/passwd", "a/b"] {
            XCTAssertEqual(NotificationService.cacheFileName(forPost: id), PhotoDropCache.fileName(forPost: id))
        }
        XCTAssertEqual(PhotoDropCache.fileName(forPost: "../../etc/passwd"), "etcpasswd.jpg", "an id never becomes a path")
    }

    func testTheExtensionLeavesThePhotoWhereTheActivityLooks() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("jpeg".utf8).write(to: source)
        let postID = "cachetest" + String(Int.random(in: 1000...9999))

        NotificationService.cacheForLiveActivity(source, postID: postID)

        let cached = try XCTUnwrap(PhotoDropCache.url(forPost: postID))
        XCTAssertEqual(try Data(contentsOf: cached), Data("jpeg".utf8))
        try? FileManager.default.removeItem(at: cached)
    }

    func testOldPhotosAreClearedOut() throws {
        let directory = try XCTUnwrap(PhotoDropCache.directory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("stale" + String(Int.random(in: 1000...9999)) + ".jpg")
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: stale.path)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("new".utf8).write(to: source)

        let freshID = "fresh" + String(Int.random(in: 1000...9999))
        NotificationService.cacheForLiveActivity(source, postID: freshID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a two-day-old photo is still cached")
        if let fresh = PhotoDropCache.url(forPost: freshID) { try? FileManager.default.removeItem(at: fresh) }
    }
}
