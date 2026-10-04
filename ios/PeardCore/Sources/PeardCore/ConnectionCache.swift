import Foundation

/// The connection list as it was last seen, and when that was.
///
/// `savedAt` is the moment the server's answer arrived, not the moment it was
/// written, so "last updated" describes the data rather than the file.
public struct CachedConnections: Codable, Sendable, Equatable {
    public let connections: [Connection]
    public let savedAt: Date

    public init(connections: [Connection], savedAt: Date) {
        self.connections = connections
        self.savedAt = savedAt
    }
}

/// Where the last-known connection list is kept between launches.
///
/// A protocol so `AppModel` can be tested against a temporary file, and so a
/// test can assert that a failure *read* the cache rather than inventing a list.
public protocol ConnectionCaching: Sendable {
    func loadConnections() -> CachedConnections?
    func saveConnections(_ connections: [Connection], at: Date)
    /// Forgets the cached list, on sign-out and account deletion.
    func clear()
}

/// A `ConnectionCaching` backed by a JSON file.
///
/// The list is what the app is *for* — without it there is no timeline, no
/// tallies and no rail — so it is cached the way the send queue is: a file, an
/// atomic write, and a decoder that will not throw the whole thing away over one
/// bad row. Losing it offline is the difference between "your moments are still
/// here" and a screen that says you have no connections.
public struct FileConnectionCache: ConnectionCaching {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The cache file inside the App Group container, so the widget and the
    /// extensions could read it later. Falls back to Application Support when
    /// the container is unavailable, which is the case in unit tests and on a
    /// misconfigured provisioning profile.
    public static func appGroup(
        identifier: String = SharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> FileConnectionCache {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FileConnectionCache(url: directory.appendingPathComponent("connections-cache.json"))
    }

    public func loadConnections() -> CachedConnections? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // `try?` rather than a throw: an unreadable cache is a cache miss, and
        // the caller already knows how to carry on without one.
        return try? JSONDecoder.peard.decode(CachedConnections.self, from: data)
    }

    public func saveConnections(_ connections: [Connection], at date: Date) {
        // Nothing to remember is not the same as remembering nothing: leaving the
        // old file in place would resurrect connections somebody has since left.
        guard !connections.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.peard.encode(CachedConnections(connections: connections, savedAt: date)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `.atomic` so a crash mid-write cannot leave a truncated list, which
        // would read back as no connections at all.
        try? data.write(to: url, options: .atomic)
    }

    /// Forgets the cached list, on sign-out and account deletion.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
