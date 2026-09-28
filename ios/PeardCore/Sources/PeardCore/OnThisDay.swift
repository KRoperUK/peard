import Foundation

/// "A year ago today" (issue #12): the moments a connection logged on this
/// calendar day last year.
///
/// One thing occasionally rather than a feed — the card only appears when
/// there is something, and there is no notification, because a daily nudge
/// becomes noise and gets muted, costing the channel quick-send relies on.
public enum OnThisDay {
    /// Local midnight to midnight, on this date one year earlier. The 29th of
    /// February, a year on, has no twin; it gets the 28th rather than nothing.
    public static func window(for date: Date, calendar: Calendar = .current) -> DateInterval? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year else { return nil }
        parts.year = year - 1
        if parts.month == 2, parts.day == 29,
           !DateComponents(year: year - 1, month: 2, day: 29).isValidDate(in: calendar) {
            parts.day = 28
        }
        guard let start = calendar.date(from: parts),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The PocketBase clause for a window, on `happened_at` — so a moment
    /// rewound to last night counts on last night.
    public static func clause(for window: DateInterval) -> String {
        PeardFilter.and(
            "happened_at >= \"\(PeardDate.format(window.start))\"",
            "happened_at < \"\(PeardDate.format(window.end))\""
        )
    }
}
