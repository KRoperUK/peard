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
        try backdate("sent-already", by: 3600)

        store.removeAll(except: ["keep-me"])

        XCTAssertEqual(store.load(for: "keep-me"), Data("jpeg".utf8))
        XCTAssertNil(store.load(for: "sent-already"))
    }

    /// A photo is written to disk just before its send is queued. A flush
    /// finishing between the two sees the send as absent; without the grace
    /// period its cleanup deletes the file, and the next flush drops the
    /// moment as permanently missing (#435).
    func testAFreshPhotoSurvivesAPruneThatCannotSeeItsSend() throws {
        try store.save(Data("jpeg".utf8), for: "just-written")

        store.removeAll(except: [])

        XCTAssertEqual(store.load(for: "just-written"), Data("jpeg".utf8))
    }

    /// The grace period only protects the just-written: a stale file with no
    /// send is still rubbish, and still goes.
    func testAnOldPhotoWithoutASendIsStillPruned() throws {
        try store.save(Data("jpeg".utf8), for: "stale")
        try backdate("stale", by: 3600)

        store.removeAll(except: [])

        XCTAssertNil(store.load(for: "stale"))
    }

    /// An explicit deletion takes the photo now: the grace period is for a
    /// flush that finished mid-queueing, not for a send known gone.
    func testRemoveForDeletesImmediately() throws {
        try store.save(Data("jpeg".utf8), for: "gone")

        store.remove(for: "gone")

        XCTAssertNil(store.load(for: "gone"))
    }

    private func backdate(_ sendID: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: store.url(for: sendID).path
        )
    }

    func testASendIDNeverBecomesAPath() {
        let url = store.url(for: "../../etc/passwd")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(url.lastPathComponent, "etcpasswd.jpg")
    }
}
