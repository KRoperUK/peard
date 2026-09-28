import Foundation

/// How often the home screen re-reads everything while it is on screen
/// (Requirement 11.12).
///
/// Every thirty seconds is the right rate when polling is the only way to hear
/// about a new moment. Once notifications are allowed it is not: the server
/// follows every new-moment alert with a silent push, and that push already
/// refreshes the home screen through `onHomeRefreshRequested`. Polling at the
/// same rate on top of it spends a round of requests — and battery — every
/// half-minute to learn what the push said. The poll stays, slower, because
/// iOS throttles silent pushes as it sees fit and only new moments send one;
/// a reaction or a rename still waits for the poll.
public enum HomePoll {
    public static let withoutPush: Duration = .seconds(30)
    public static let withPush: Duration = .seconds(120)

    /// The wait before the next poll. Asked afresh each time round, so allowing
    /// or revoking notifications in Settings takes effect on the next cycle.
    public static func interval(pushAuthorised: Bool) -> Duration {
        pushAuthorised ? withPush : withoutPush
    }
}
