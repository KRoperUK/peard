import XCTest
@testable import PeardCore

/// The hand-off from an extension that could not reach the server to the app
/// that will. Like the send queue, the two ways to get it wrong are losing a
/// moment and sending one twice.
final class MomentInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: MomentInbox!
    private var queue: SendQueue!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-inbox-\(UUID().uuidString)")
        inbox = MomentInbox(url: directory.appendingPathComponent("extension-inbox.json"))
        queue = SendQueue(store: FilePendingSendStore(url: directory.appendingPathComponent("pending-sends.json")))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        inbox = nil
        queue = nil
        directory = nil
        super.tearDown()
    }

    private func moment(id: String = UUID().uuidString, pair: String? = "p1") -> InboxedMoment {
        InboxedMoment(
            id: id, pairID: pair, kind: .beer, emoji: "🍺", label: "Beer",
            queuedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    // MARK: The extension's side

    func testAppendedMomentsSurviveOnDisk() {
        inbox.append(moment(id: "a"))
        inbox.append(moment(id: "b"))

        // A fresh instance, as the app would have: nothing held in memory.
        let reread = MomentInbox(url: inbox.url).load()
        XCTAssertEqual(reread.map(\.id), ["a", "b"])
    }

    /// An intent the system re-runs must not inbox the same tap twice.
    func testAppendingTheSameIDTwiceKeepsOne() {
        inbox.append(moment(id: "a"))
        inbox.append(moment(id: "a"))

        XCTAssertEqual(inbox.load().count, 1)
    }

    // MARK: The app's side

    func testMergeMovesMomentsIntoTheQueueAndEmptiesTheInbox() async {
        inbox.append(moment(id: "a"))

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 1)
        XCTAssertTrue(inbox.load().isEmpty)
        let queued = await queue.pending
        XCTAssertEqual(queued.map(\.id), ["a"])
        XCTAssertEqual(queued.first?.authorID, "me")
        XCTAssertEqual(queued.first?.pairID, "p1")
        XCTAssertEqual(queued.first?.queuedAt, Date(timeIntervalSince1970: 1_790_000_000))
        // The extension's client id goes out again, so a first attempt that did
        // land cannot be logged a second time.
        XCTAssertEqual(queued.first?.postFields["client_id"], "a")
    }

    /// A crash after queueing but before the inbox was emptied leaves the
    /// moment in both. The next merge must not queue it again.
    func testMergingTwiceDoesNotDuplicate() async {
        let leftover = moment(id: "a")
        inbox.append(leftover)
        await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)
        inbox.append(leftover)

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 0)
        let count = await queue.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(inbox.load().isEmpty)
    }

    /// Control Centre and Siri name no connection; the app supplies one.
    func testAMomentWithNoConnectionTakesTheFallback() async {
        inbox.append(moment(id: "a", pair: nil))

        await queue.absorb(inbox, authorID: "me", fallbackPairID: "p2")

        let queued = await queue.pending
        XCTAssertEqual(queued.first?.pairID, "p2")
    }

    /// With nowhere to put it yet, it waits rather than being dropped.
    func testAMomentWithNowhereToGoStaysInTheInbox() async {
        inbox.append(moment(id: "a", pair: nil))
        inbox.append(moment(id: "b"))

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 1)
        XCTAssertEqual(inbox.load().map(\.id), ["a"])
    }

    /// No session means no author, so nothing can be queued yet.
    func testNothingIsTakenWithoutAnAuthor() async {
        inbox.append(moment(id: "a"))

        let added = await queue.absorb(inbox, authorID: "", fallbackPairID: nil)

        XCTAssertEqual(added, 0)
        XCTAssertEqual(inbox.load().count, 1)
    }

    /// Removal names what it read, so something the extension appended in the
    /// meantime is not swept away with it.
    func testRemovingKeepsEntriesAppendedSinceTheyWereRead() {
        inbox.append(moment(id: "a"))
        let read = Set(inbox.load().map(\.id))
        inbox.append(moment(id: "b"))

        inbox.remove(ids: read)

        XCTAssertEqual(inbox.load().map(\.id), ["b"])
    }

    // MARK: Photos from the share extension

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])

    private var photos: PendingPhotoStore {
        PendingPhotoStore(directory: directory.appendingPathComponent("PendingPhotos"))
    }

    private func shared(id: String = "s1", kind: EventKind = .coffee, pair: String? = "p1") -> InboxedMoment {
        InboxedMoment(
            id: id, pairID: pair, kind: kind, emoji: "☕", label: "Coffee",
            queuedAt: Date(timeIntervalSince1970: 1_790_000_000),
            note: "flat white", hasPhoto: true
        )
    }

    /// An inbox written before photos existed has neither field, and must still
    /// load — a decoding failure would lose every moment waiting in it.
    func testAnInboxFromBeforePhotosStillLoads() throws {
        let old = """
        [{"id":"a","pair":"p1","kind":"beer","emoji":"🍺","label":"Beer","queued_at":"2026-09-21 12:00:00.000Z"}]
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: inbox.url)

        let loaded = inbox.load()

        XCTAssertEqual(loaded.map(\.id), ["a"])
        XCTAssertEqual(loaded.first?.note, "")
        XCTAssertEqual(loaded.first?.hasPhoto, false)
    }

    func testAPhotoIsWrittenBesideItsEntry() {
        XCTAssertTrue(inbox.append(shared(), photo: jpeg))

        XCTAssertEqual(inbox.load().first?.hasPhoto, true)
        XCTAssertEqual(inbox.loadPhoto(for: "s1"), jpeg)
    }

    /// The app's queue uploads it: the photo moves to the pending photo store
    /// under the send's id, with the note, before the send is queued.
    func testAbsorbingASharedPhotoQueuesItWithItsFile() async {
        inbox.append(shared(), photo: jpeg)

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil, photos: photos)

        XCTAssertEqual(added, 1)
        let send = await queue.pending.first
        XCTAssertEqual(send?.id, "s1")
        XCTAssertEqual(send?.hasPhoto, true)
        XCTAssertEqual(send?.postType, .event)
        XCTAssertEqual(send?.note, "flat white")
        XCTAssertEqual(photos.load(for: "s1"), jpeg)
        // Gone from the inbox, file and all, now the queue holds it.
        XCTAssertTrue(inbox.load().isEmpty)
        XCTAssertNil(inbox.loadPhoto(for: "s1"))
    }

    /// With no moment chosen it is a plain photo, as when shared in the app.
    func testASharedPhotoWithNoMomentIsAPhotoPost() async {
        inbox.append(shared(kind: EventKind(rawValue: "")), photo: jpeg)

        await queue.absorb(inbox, authorID: "me", fallbackPairID: nil, photos: photos)

        let send = await queue.pending.first
        XCTAssertEqual(send?.postType, .photo)
        XCTAssertNil(send?.postFields["event_kind"])
    }

    /// Queued without its file, the send would fail at upload; left in the
    /// inbox, it waits for a caller that can place the photo.
    func testAPhotoWaitsWhenThereIsNowhereToPutIt() async {
        inbox.append(shared(), photo: jpeg)

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil)

        XCTAssertEqual(added, 0)
        XCTAssertEqual(inbox.load().map(\.id), ["s1"])
        XCTAssertEqual(inbox.loadPhoto(for: "s1"), jpeg)
    }

    /// No later merge can bring back a file that has gone, so the entry goes
    /// too rather than being retried for ever.
    func testAnEntryWhosePhotoHasGoneIsDropped() async throws {
        inbox.append(shared(), photo: jpeg)
        try FileManager.default.removeItem(at: inbox.photoURL(for: "s1"))

        let added = await queue.absorb(inbox, authorID: "me", fallbackPairID: nil, photos: photos)

        XCTAssertEqual(added, 0)
        XCTAssertTrue(inbox.load().isEmpty)
    }

    /// The inbox's photos must not sit where the app prunes after each flush,
    /// or one shared between an absorb and a prune would be deleted unsent.
    /// Both stores are built from the same container directory in the app, as
    /// they are here.
    func testInboxPhotosAreNotWhereTheQueuePrunes() {
        inbox.append(shared(), photo: jpeg)

        photos.removeAll(except: [])

        XCTAssertEqual(inbox.loadPhoto(for: "s1"), jpeg)
    }

    /// The share sheet's entry matches a photo shared in the app: "📸 Photo"
    /// with no kind when no moment was chosen, and the caption normalised.
    func testASharedPhotoWithNoMomentIsFilledInLikeTheApps() {
        let entry = InboxedMoment.sharedPhoto(pairID: "p1", moment: nil, caption: "  sunset  ")

        XCTAssertEqual(entry.kind.rawValue, "")
        XCTAssertEqual(entry.emoji, "📸")
        XCTAssertEqual(entry.label, "Photo")
        XCTAssertEqual(entry.note, "sunset")
        XCTAssertTrue(entry.hasPhoto)
    }

    func testASharedPhotoCarriesItsMomentAndACappedCaption() {
        let walk = WidgetFeed.AvailableMoment(kind: EventKind(rawValue: "dog_walk"), emoji: "🐕", label: "Dog walk")

        let entry = InboxedMoment.sharedPhoto(
            pairID: "p1", moment: walk, caption: String(repeating: "a", count: PostNote.limit + 20)
        )

        XCTAssertEqual(entry.kind.rawValue, "dog_walk")
        XCTAssertEqual(entry.label, "Dog walk")
        XCTAssertEqual(entry.note.count, PostNote.limit)
    }

    func testAPhotoIDNeverBecomesAPath() {
        XCTAssertEqual(inbox.photoURL(for: "../../etc/passwd").deletingLastPathComponent(), inbox.photoDirectory)
    }
}
