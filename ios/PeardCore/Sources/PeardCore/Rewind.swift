import Foundation

/// Logging a moment after the fact, up to a day back.
///
/// The server enforces the same rules in `internal/posts`; these are here so the
/// picker never offers a time it would refuse. A rewound moment sorts and counts
/// at the time it happened, but carries a "Rewound" chip so nobody mistakes it
/// for something logged in the moment.
public enum Rewind {
    /// How far back a moment can go, measured from when it was logged.
    public static let window: TimeInterval = 24 * 60 * 60

    /// Less than this far back is still "in the moment". The picker opens on
    /// now, and a few seconds' fiddling with it is not a rewind.
    public static let threshold: TimeInterval = 60

    /// The times a moment logged at `loggedAt` can be set to.
    public static func range(loggedAt: Date) -> ClosedRange<Date> {
        loggedAt.addingTimeInterval(-window)...loggedAt
    }

    /// Whether `happenedAt` is far enough before `loggedAt` to earn the chip.
    public static func isRewound(_ happenedAt: Date, loggedAt: Date) -> Bool {
        loggedAt.timeIntervalSince(happenedAt) > threshold
    }

    /// The form the server reads a time in.
    public static func wireString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
