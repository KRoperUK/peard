import Foundation

/// What the watch shows besides the moment grid (issue #287): a tile to log the
/// last moment again, a line of today's counts, and how much the Smart Stack
/// should want the rectangular widget.
///
/// Kept here rather than in the watch targets because neither has a test
/// target, the same reason `LockScreenSummary` lives here.
public enum WatchGlance {
    // MARK: Log again

    /// The moment the log-again tile offers, or nil when it would not earn its
    /// space.
    ///
    /// Resolved against what the connection offers now, so a custom moment that
    /// has since been deleted is not offered from memory. And skipped when the
    /// moment already sits in the grid's first row, which is on screen anyway —
    /// a tile above its own twin is a second copy of the same tap, not a saved
    /// scroll.
    /// - Parameter firstRow: how many moments the grid's first row holds.
    public static func logAgain(
        lastKind: String?,
        in moments: [WidgetFeed.AvailableMoment],
        firstRow: Int
    ) -> WidgetFeed.AvailableMoment? {
        guard let lastKind, let index = moments.firstIndex(where: { $0.kind.rawValue == lastKind }) else { return nil }
        return index < firstRow ? nil : moments[index]
    }

    // MARK: Today

    /// One line of today's counts, or nil when there are none — an empty line
    /// is not worth a row on a 41 mm screen.
    ///
    /// Named for whose counts they are, because the server counts only the
    /// other members' moments: without it, logging a coffee from the watch and
    /// seeing the coffee count not move reads as a bug.
    public static func todayLine(_ feed: WidgetFeed) -> String? {
        guard let tallies = LockScreenSummary.talliesText(feed.displayTallies) else { return nil }
        return "\(whose(feed)) today  \(tallies)"
    }

    /// The same line for VoiceOver, every count in words rather than the three
    /// emoji that fit on screen.
    public static func todayAccessibilityLabel(_ feed: WidgetFeed) -> String? {
        let tallies = feed.displayTallies
        guard !tallies.isEmpty else { return nil }
        let counts = tallies.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
        return "Today from \(whose(feed)): \(counts)"
    }

    private static func whose(_ feed: WidgetFeed) -> String {
        // In a group the feed's partner is whoever posted last, which is not
        // whose counts these are.
        feed.isGroup ? "Others" : feed.partnerName
    }

    // MARK: Smart Stack

    /// How strongly the Smart Stack should surface the rectangular widget, on
    /// WidgetKit's relative scale: a score above zero and how long it holds.
    public struct Relevance: Equatable, Sendable {
        public let score: Float
        public let duration: TimeInterval
    }

    /// Something the person has not seen yet is the whole reason to rotate a
    /// widget to the top, so relevance follows how recent the latest moment
    /// is: high just after it lands, lower for the next few hours, and nothing
    /// after that or when there is only a prompt. The watch app's own logs are
    /// not in the feed's latest moment, so a run of taps does not promote it.
    public static func smartStackRelevance(_ summary: LockScreenSummary, now: Date) -> Relevance {
        guard !summary.isPrompt, let at = summary.at else { return Relevance(score: 0, duration: 0) }
        let age = max(0, now.timeIntervalSince(at))
        if age < freshFor { return Relevance(score: 100, duration: freshFor - age) }
        if age < recentFor { return Relevance(score: 40, duration: recentFor - age) }
        return Relevance(score: 0, duration: 0)
    }

    static let freshFor: TimeInterval = 30 * 60
    static let recentFor: TimeInterval = 3 * 60 * 60
}
