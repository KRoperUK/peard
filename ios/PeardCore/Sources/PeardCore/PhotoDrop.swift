import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// A Live Activity for a connection that is sharing photos.
///
/// Started and updated by push only: the server starts it with this device's
/// push-to-start token when a photo arrives, and updates it with the activity's
/// own token for each photo in the thirty minutes after. The field names are the
/// wire format — the server writes `attributes` and `content-state` with these
/// exact keys (see `server/internal/push/liveactivity.go`), and the type name is
/// what it sends as `attributes-type`, so renaming either breaks every start.
public struct PhotoDropAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The latest photo, which is also the name its thumbnail is cached
        /// under by the notification service extension.
        public var postID: String
        public var authorName: String
        public var caption: String
        /// Photos in this connection in the last thirty minutes.
        public var count: Int
        /// Unix seconds. Not a `Date`: ActivityKit decodes a bare `Date` as
        /// seconds since 2001, and the server has no reason to know that.
        public var updatedAt: Double

        public init(postID: String, authorName: String, caption: String, count: Int, updatedAt: Double) {
            self.postID = postID
            self.authorName = authorName
            self.caption = caption
            self.count = count
            self.updatedAt = updatedAt
        }

        public var updated: Date { Date(timeIntervalSince1970: updatedAt) }
    }

    public var pairID: String
    /// The connection's name, or the other person's in a pair.
    public var title: String

    public init(pairID: String, title: String) {
        self.pairID = pairID
        self.title = title
    }
}
#endif

/// Where the notification service extension leaves a photo moment's thumbnail,
/// so the Live Activity — which has no network of its own — can show it.
///
/// The extension does not link PeardCore (it runs in about 24 MB), so it keeps
/// its own copy of this path; `PhotoDropCacheTests` pins the two together.
public enum PhotoDropCache {
    public static let directoryName = "PhotoDrops"

    public static func directory(appGroup: String = SharedStore.appGroupIdentifier) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func fileName(forPost postID: String) -> String {
        // Post ids are PocketBase's 15 lowercase alphanumerics; anything else is
        // not ours, and must not become a path.
        let safe = postID.filter { $0.isLetter || $0.isNumber }
        return safe + ".jpg"
    }

    public static func url(forPost postID: String, appGroup: String = SharedStore.appGroupIdentifier) -> URL? {
        directory(appGroup: appGroup)?.appendingPathComponent(fileName(forPost: postID))
    }
}
