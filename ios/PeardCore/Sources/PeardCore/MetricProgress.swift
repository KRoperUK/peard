import Foundation

/// Today's amount of a metric measured against a daily minimum and goal (#386).
///
/// The unit-agnostic generalisation of `WaterProgress`: the amount is a
/// canonical whole number (ml, steps, minutes), so the stages and fractions are
/// the same arithmetic whatever the metric. Pure, so thresholds can be asserted
/// without rendering a ring. Water's own `WaterProgress` stays as the hero's
/// richer type; this is what a steps or exercise metric measures by.
public struct MetricProgress: Equatable, Sendable {
    /// Where today's amount stands, ordered so "at least this far" is `>=`.
    public enum Stage: Int, Comparable, Sendable {
        case none
        case underMinimum
        case minimumMet
        case goalMet

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let amount: Int
    public let minimum: Int
    public let goal: Int

    /// A negative amount counts as none. A minimum above the goal is pulled down
    /// to it, and a goal below 1 is raised to 1, so the fraction can never divide
    /// by zero or exceed one.
    public init(amount: Int, minimum: Int, goal: Int) {
        self.amount = max(amount, 0)
        self.goal = max(goal, 1)
        self.minimum = min(max(minimum, 0), self.goal)
    }

    /// Progress toward the goal, 0...1. Stops at 1 however far over.
    public var fraction: Double { min(Double(amount) / Double(goal), 1) }

    /// Where the minimum sits on the same 0...1 scale, for a marker.
    public var minimumFraction: Double { Double(minimum) / Double(goal) }

    public var isMinimumMet: Bool { amount >= minimum && amount > 0 }
    public var isGoalMet: Bool { amount >= goal }

    /// Still to go to reach the goal; 0 once met.
    public var remaining: Int { max(goal - amount, 0) }

    public var stage: Stage {
        if amount == 0 { return .none }
        if isGoalMet { return .goalMet }
        if isMinimumMet { return .minimumMet }
        return .underMinimum
    }
}
