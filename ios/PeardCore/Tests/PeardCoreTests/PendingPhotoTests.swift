import XCTest
@testable import PeardCore

/// Queued photos (issue #2): the send that describes one, and the file behind it.
final class PendingPhotoTests: XCTestCase {
    private var directory: URL!
    private var store: PendingPhotoStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-photos-\(UUID().uuidString)")
        store = PendingPhotoStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: The send

    /// A queue written by the build before this one has neither new key. It
    /// must still load, or an update would lose every moment waiting in it.
    func testAQueueFromBeforePhotosStillLoads() throws {
        let json = #"""
        [{"id":"s1","pair":"x","author":"a","kind":"beer","emoji":"🍺","label":"Beer","note":"",
          "queued_at":"2026-09-27 12:00:00.000Z","attempts":0}]
        """#
        let sends = try JSONDecoder.peard.decode([PendingSend].self, from: Data(json.utf8))
        XCTAssertEqual(sends.first?.postType, .event)
        XCTAssertEqual(sends.first?.hasPhoto, false)
    }

    func testAPhotoWithNoMomentPostsAsAPhoto() {
        let send = PendingSend(pairID: "x", authorID: "a", kind: EventKind(rawValue: ""), emoji: "📸", label: "Photo",
                               postType: .photo, hasPhoto: true)
        XCTAssertEqual(send.postFields["type"], "photo")
        XCTAssertNil(send.postFields["event_kind"], "a photo has no kind to send")
        XCTAssertEqual(send.optimisticPost.type, .photo)
    }

    func testAPhotoOfAMomentPostsAsThatMoment() {
        let send = PendingSend(pairID: "x", authorID: "a", kind: .coffee, emoji: "☕", label: "Coffee",
                               postType: .event, hasPhoto: true)
        XCTAssertEqual(send.postFields["type"], "event")
        XCTAssertEqual(send.postFields["event_kind"], "coffee")
    }

    func testTheSendSurvivesARelaunch() throws {
        let send = PendingSend(pairID: "x", authorID: "a", kind: EventKind(rawValue: ""), emoji: "📸", label: "Photo",
                               postType: .photo, hasPhoto: true)
        let decoded = try JSONDecoder.peard.decode(PendingSend.self, from: JSONEncoder.peard.encode(send))
        XCTAssertEqual(decoded.postType, .photo)
        XCTAssertTrue(decoded.hasPhoto)
    }

    /// A photo with nothing attached is not a beer, and must not count as one
    /// while it waits.
    func testAQueuedPhotoCountsInNoTally() {
        let photo = PendingSend(pairID: "p", authorID: "a", kind: EventKind(rawValue: ""), emoji: "📸", label: "Photo",
                                postType: .photo, hasPhoto: true)
        let tallies = ConnectionTallies(pair: "p", mine: .zero, others: .zero, kinds: []).adding(pending: [photo])
        XCTAssertEqual(tallies.mine.all, 0)
        XCTAssertTrue(tallies.kinds.isEmpty)
    }

    // MARK: The file

    func testAPhotoIsKeptUntilItsSendIsGone() throws {
        try store.save(Data("jpeg".utf8), for: "keep-me")
        try store.save(Data("jpeg".utf8), for: "sent-already")

        store.removeAll(except: ["keep-me"])

        XCTAssertEqual(store.load(for: "keep-me"), Data("jpeg".utf8))
        XCTAssertNil(store.load(for: "sent-already"))
    }

    func testASendIDNeverBecomesAPath() {
        let url = store.url(for: "../../etc/passwd")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(url.lastPathComponent, "etcpasswd.jpg")
    }
}
