import Foundation

/// Whether re-reading a screen's content on its appearance is worth a request.
///
/// A tab's `.task` runs every time the tab is shown, so switching Home →
/// Timeline → Home re-fetched everything both screens had fetched seconds
/// before (issue #302's audit). The poll, the foreground hook and the silent
/// push already keep the content fresh; an appearance only needs to fetch when
/// none of those has for a while, or when what it is keyed on has changed.
public struct RefreshGate: Sendable {
    /// How long a fetch stays good enough to skip a re-read on appearance.
    /// The home screen's fastest poll interval: anything newer than a poll
    /// would have been is as fresh as the screen ever is.
    public static let defaultWindow: TimeInterval = 30

    public let window: TimeInterval
    private var lastKey: String?
    private var lastAt: Date?

    public init(window: TimeInterval = RefreshGate.defaultWindow) {
        self.window = window
    }

    public func isDue(key: String = "", now: Date = Date()) -> Bool {
        guard let lastAt, lastKey == key else { return true }
        return now.timeIntervalSince(lastAt) >= window
    }

    /// Notes a fetch. Called when it starts rather than when it lands, so an
    /// appearance during a fetch already in flight does not start a second.
    public mutating func record(key: String = "", at now: Date = Date()) {
        lastKey = key
        lastAt = now
    }
}
