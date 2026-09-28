import Foundation

/// The JPEG behind a queued photo moment, kept on disk until the send lands.
///
/// A queued moment is a few hundred bytes of JSON; a photo is a megabyte, so it
/// lives beside the queue rather than in it, named by the send's id. It is
/// written *before* the send is queued — a photo that is on disk is one that
/// survives no signal, the app being killed, and the sheet having gone. Files
/// whose send is no longer queued (sent, discarded, or aged out by the queue)
/// are removed by `removeAll(except:)` after each flush, so nothing outlives
/// its send.
public struct PendingPhotoStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Next to the queue file in the App Group container, with the same
    /// fallback when there is no container (tests, a bad profile).
    public static func appGroup(
        identifier: String = SharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> PendingPhotoStore {
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return PendingPhotoStore(directory: base.appendingPathComponent("PendingPhotos", isDirectory: true))
    }

    public func url(for sendID: String) -> URL {
        directory.appendingPathComponent(sendID.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".jpg")
    }

    public func save(_ data: Data, for sendID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: sendID), options: .atomic)
    }

    public func load(for sendID: String) -> Data? {
        try? Data(contentsOf: url(for: sendID))
    }

    /// Deletes every photo whose send is not in `keep`.
    public func removeAll(except keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let kept = Set(keep.map { url(for: $0).lastPathComponent })
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A queued photo whose file has gone, which no retry can fix.
public struct MissingPendingPhoto: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "The photo for this moment is no longer on the phone." }
}
