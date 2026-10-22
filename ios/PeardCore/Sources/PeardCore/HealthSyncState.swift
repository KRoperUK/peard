import Foundation

/// The last Apple Health figure pushed for one metric on one day (#411).
///
/// Kept so a foreground refresh can tell "nothing has moved" from "the total
/// changed" without a round trip to the server. The day is part of the state:
/// a new day must push even when the figure happens to be the same.
public struct HealthSyncState: Codable, Equatable, Sendable {
    /// The member's local calendar day, `yyyy-MM-dd`.
    public let day: String
    /// The cumulative total pushed for that day.
    public let amount: Int

    public init(day: String, amount: Int) {
        self.day = day
        self.amount = amount
    }
}
