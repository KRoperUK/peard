import Foundation

/// A moment an extension could not get to the server, waiting for the app to
/// pick it up.
///
/// Not a `PendingSend`, because an extension cannot fill one in. It has no
/// session, so it does not know the author; and a Control Centre button or a
/// spoken "log a beer" names no connection at all, leaving the server to pick
/// the liveliest. Both are decided by the app when it takes the moment in.
///
/// The share extension hands photos over the same way, and for the same
/// reasons — plus one of its own: it must not upload. A share extension is
/// given a small memory budget and is gone the moment the sheet closes, so an
/// upload started there would be cut off on exactly the connections where it
/// matters. The app's queue already knows how to retry a photo until it lands.
public struct InboxedMoment: Codable, Hashable, Sendable, Identifiable {
    /// The `client_id` the extension's own attempt went out with, reused as the
    /// queued send's id. If that attempt did land and only the response was
    /// lost, the app's retry is refused by the server's unique index instead of
    /// logging the moment twice.
    public let id: String
    /// `nil` for "whichever connection is liveliest".
    public let pairID: String?
    public let kind: EventKind
    public let emoji: String
    public let label: String
    /// When it was tapped, so it lands at that time rather than whenever the
    /// app next came to the foreground.
    public let queuedAt: Date
    /// A note on the moment, or a photo's caption. Empty for a control or a
    /// spoken phrase, which have nowhere to type one.
    public let note: String
    /// A JPEG waits beside the inbox under this moment's id — see
    /// `MomentInbox.photoURL(for:)`. Only the share extension sets it.
    ///
    /// A flag rather than a path in the JSON, so nothing read from this file
    /// can point the app at a file outside the inbox's own folder.
    public let hasPhoto: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, emoji, label, note
        case pairID = "pair"
        case queuedAt = "queued_at"
        case hasPhoto = "has_photo"
    }

    public init(
        id: String = UUID().uuidString,
        pairID: String?,
        kind: EventKind,
        emoji: String,
        label: String,
        queuedAt: Date = Date(),
        note: String = "",
        hasPhoto: Bool = false
    ) {
        self.id = id
        self.pairID = pairID
        self.kind = kind
        self.emoji = emoji
        self.label = label
        self.queuedAt = queuedAt
        self.note = note
        self.hasPhoto = hasPhoto
    }

    /// A photo from the share extension, with the moment it was shared as, if
    /// any.
    ///
    /// Filled in the way `HomeModel.upload` fills in a photo shared in the
    /// app — "📸 Photo" and no kind when no moment was chosen, the caption
    /// normalised — so the two arrive as the same kind of post.
    public static func sharedPhoto(
        pairID: String?,
        moment: WidgetFeed.AvailableMoment?,
        caption: String,
        at date: Date = Date()
    ) -> InboxedMoment {
        InboxedMoment(
            pairID: pairID,
            kind: moment?.kind ?? EventKind(rawValue: ""),
            emoji: moment?.emoji ?? "📸",
            label: moment?.label ?? "Photo",
            queuedAt: date,
            note: PostNote.normalised(caption),
            hasPhoto: true
        )
    }

    /// Written by hand so an inbox left by an older build still loads: its
    /// entries have no `note` or `has_photo`, and the synthesized decoder would
    /// reject the whole file — every moment in it with them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pairID = try c.decodeIfPresent(String.self, forKey: .pairID)
        kind = try c.decode(EventKind.self, forKey: .kind)
        emoji = try c.decode(String.self, forKey: .emoji)
        label = try c.decode(String.self, forKey: .label)
        queuedAt = try c.decode(Date.self, forKey: .queuedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
    }

    /// The send the app queues for it, or `nil` while there is no connection to
    /// put it in.
    ///
    /// A moment that named no connection goes to `fallbackPairID`, which the app
    /// passes as the connection it has selected. The server's "liveliest" rule
    /// is not something the app can reproduce offline, and asking the server
    /// first would put a network round trip in front of a queue whose whole job
    /// is working without one. For somebody in a single connection — most
    /// people — the two answers are the same.
    public func pendingSend(authorID: String, fallbackPairID: String?) -> PendingSend? {
        guard let pair = pairID ?? fallbackPairID, !pair.isEmpty else { return nil }
        return PendingSend(
            id: id,
            pairID: pair,
            authorID: authorID,
            kind: kind,
            emoji: emoji,
            label: label,
            note: note,
            queuedAt: queuedAt,
            // The same rule as a photo shared from inside the app: with a
            // moment it is an event that carries a picture, and counts; with
            // none it is a plain photo.
            postType: hasPhoto && kind.rawValue.isEmpty ? .photo : .event,
            hasPhoto: hasPhoto
        )
    }
}

/// A file in the App Group container that the extensions add to and the app
/// empties into its `SendQueue`.
///
/// Separate from `pending-sends.json` on purpose. That file belongs to the
/// app's `SendQueue`, which holds it in memory and rewrites it whole: an
/// extension writing to it underneath would either be overwritten by the next
/// save or would resurrect a send the queue had just delivered. Here the only
/// writers are an append and a removal of named entries, both read-modify-write
/// under an `NSFileCoordinator`, so neither side can drop the other's change.
public struct MomentInbox: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Beside the send queue's file, with the same fallback when the container
    /// is unavailable.
    public static func appGroup(
        identifier: String = SharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> MomentInbox {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return MomentInbox(url: directory.appendingPathComponent("extension-inbox.json"))
    }

    /// Everything waiting, oldest first.
    public func load() -> [InboxedMoment] {
        var moments: [InboxedMoment] = []
        coordinate(.reading) { moments = read() }
        return moments
    }

    /// Where the JPEG behind an entry with `hasPhoto` waits: a folder beside
    /// the inbox file, named by the entry's id.
    ///
    /// Not `PendingPhotoStore`'s folder, although the file ends up there. The
    /// app clears that folder of everything its queue does not hold after each
    /// flush, and a photo the extension had just written but the app had not
    /// yet absorbed would be deleted out from under it.
    public var photoDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("InboxPhotos", isDirectory: true)
    }

    public func photoURL(for id: String) -> URL {
        photoDirectory.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".jpg")
    }

    public func loadPhoto(for id: String) -> Data? {
        try? Data(contentsOf: photoURL(for: id))
    }

    /// Adds a moment with its photo.
    ///
    /// The photo is written first, so an entry is never visible without the
    /// file it names. If the entry cannot be written the photo is removed
    /// again rather than left behind with nothing to claim it.
    @discardableResult
    public func append(_ moment: InboxedMoment, photo: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
            try photo.write(to: photoURL(for: moment.id), options: .atomic)
        } catch {
            return false
        }
        guard append(moment) else {
            try? FileManager.default.removeItem(at: photoURL(for: moment.id))
            return false
        }
        return true
    }

    /// Adds a moment. One already there under the same id is left alone, so a
    /// retried intent cannot inbox the same tap twice.
    @discardableResult
    public func append(_ moment: InboxedMoment) -> Bool {
        var written = false
        coordinate(.writing) {
            var moments = read()
            guard !moments.contains(where: { $0.id == moment.id }) else {
                written = true
                return
            }
            moments.append(moment)
            written = write(moments)
        }
        return written
    }

    /// Removes the named entries, and their photos, keeping anything appended
    /// since they were read.
    public func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        coordinate(.writing) {
            write(read().filter { !ids.contains($0.id) })
        }
        for id in ids {
            try? FileManager.default.removeItem(at: photoURL(for: id))
        }
    }

    // MARK: File access

    private enum Access { case reading, writing }

    /// Runs `body` while holding the coordinator's claim on the file, so an
    /// extension's append and the app's removal are never interleaved.
    private func coordinate(_ access: Access, _ body: () -> Void) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        switch access {
        case .reading:
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in body() }
        case .writing:
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { _ in body() }
        }
    }

    private func read() -> [InboxedMoment] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.peard.decode([InboxedMoment].self, from: data)) ?? []
    }

    @discardableResult
    private func write(_ moments: [InboxedMoment]) -> Bool {
        if moments.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let data = try? JSONEncoder.peard.encode(moments) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `.atomic` for the same reason as the send queue: a crash mid-write
        // must not leave a truncated file that loses every moment in it.
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

public extension SendQueue {
    /// Moves what the extensions left in `inbox` into the queue, returning how
    /// many were added.
    ///
    /// Queued and persisted first, removed from the inbox second: a crash in
    /// between leaves a moment in both, and the next merge skips it because the
    /// queue already holds its id. The reverse order would lose it. Anything
    /// with no connection to go to yet stays in the inbox for a later merge.
    ///
    /// A photo is copied into `photos` before its send is queued, following the
    /// app's own rule that a queued photo is one already on disk. Without a
    /// `photos` store to put it in, a photo moment waits in the inbox; one whose
    /// file has gone is dropped, since no later merge can bring it back.
    @discardableResult
    func absorb(
        _ inbox: MomentInbox,
        authorID: String,
        fallbackPairID: String?,
        photos: PendingPhotoStore? = nil
    ) async -> Int {
        let waiting = inbox.load()
        guard !waiting.isEmpty, !authorID.isEmpty else { return 0 }

        var taken: Set<String> = []
        var added = 0
        for moment in waiting {
            guard let send = moment.pendingSend(authorID: authorID, fallbackPairID: fallbackPairID) else { continue }
            let alreadyQueued = pending.contains { $0.id == send.id }
            if send.hasPhoto, !alreadyQueued {
                guard let photos else { continue }
                guard let data = inbox.loadPhoto(for: moment.id) else {
                    taken.insert(moment.id)
                    continue
                }
                guard (try? photos.save(data, for: send.id)) != nil else { continue }
            }
            taken.insert(moment.id)
            guard !alreadyQueued else { continue }
            await enqueue(send)
            added += 1
        }
        inbox.remove(ids: taken)
        return added
    }
}
