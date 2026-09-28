import UniformTypeIdentifiers
import UserNotifications

/// Puts the photo in a photo moment's notification.
///
/// The server sends every photo's alert with `mutable-content` and a
/// `media_url`: the 512-point thumbnail, carrying a file token minted for this
/// recipient, because the photo is protected and this extension has no session.
/// It is downloaded and attached, so the Lock Screen shows the picture instead
/// of "Fresh pear from Ada".
///
/// It also leaves a copy in the App Group, named by `post_id`, for the photo
/// drop Live Activity to show: that activity is started by its own push and has
/// no network, so this is the only way the picture reaches it.
///
/// Deliberately small, and without PeardCore: a service extension gets about
/// 24 MB and 30 seconds. Anything that goes wrong — no URL, a failed or slow
/// download, an expired token — delivers the notification exactly as it arrived.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard
            let content = request.content.mutableCopy() as? UNMutableNotificationContent,
            let raw = request.content.userInfo["media_url"] as? String,
            let url = URL(string: raw)
        else {
            contentHandler(request.content)
            return
        }

        lock.lock()
        self.contentHandler = contentHandler
        bestAttempt = content
        lock.unlock()

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, _ in
            if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                if let postID = request.content.userInfo["post_id"] as? String {
                    Self.cacheForLiveActivity(location, postID: postID)
                }
                if let attachment = Self.attachment(movingFrom: location) {
                    content.attachments = [attachment]
                }
            }
            self?.deliver(content)
        }
        lock.lock()
        download = task
        lock.unlock()
        task.resume()
    }

    /// The system is about to give up on us: send what we have, which is the
    /// notification without its picture.
    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = download
        let content = bestAttempt
        lock.unlock()
        task?.cancel()
        if let content { deliver(content) }
    }

    /// Hands the content over exactly once, whichever of the download and the
    /// deadline gets there first.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    // Kept in step with PeardCore's PhotoDropCache by PhotoDropCacheTests.
    static let appGroup = "group.com.peard.app"
    static let cacheDirectoryName = "PhotoDrops"
    /// Long enough to outlive any activity (which goes stale in thirty
    /// minutes), short enough that the folder never becomes a photo library.
    static let cacheLifetime: TimeInterval = 24 * 60 * 60

    static func cacheFileName(forPost postID: String) -> String {
        postID.filter { $0.isLetter || $0.isNumber } + ".jpg"
    }

    /// Copies the photo into the App Group and clears out old ones. Best
    /// effort: the notification matters more than the activity's picture.
    static func cacheForLiveActivity(_ location: URL, postID: String, now: Date = Date()) {
        let files = FileManager.default
        guard let directory = files.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(cacheDirectoryName, isDirectory: true) else { return }
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(cacheFileName(forPost: postID))
        try? files.removeItem(at: destination)
        try? files.copyItem(at: location, to: destination)

        let old = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in old {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > cacheLifetime {
                try? files.removeItem(at: file)
            }
        }
    }

    /// The downloaded file is removed when the completion handler returns, and
    /// an attachment needs a file with an extension it recognises, so it moves
    /// somewhere of our own first.
    private static func attachment(movingFrom location: URL) -> UNNotificationAttachment? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            return try UNNotificationAttachment(
                identifier: "photo",
                url: destination,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier]
            )
        } catch {
            return nil
        }
    }
}
