import Foundation

/// Today's water measured against a daily minimum and a recommended amount (#321).
///
/// Pure, so the thresholds can be asserted without rendering a ring. The targets
/// are the built-in `WaterAmount.defaultMinimum` / `defaultRecommended` for now;
/// per-connection overrides are #322 and will pass their own values in.
public struct WaterProgress: Equatable, Sendable {
    /// Where today's total stands. Ordered, so "at least this far" is `>=`.
    public enum Stage: Int, Comparable, Sendable {
        /// Nothing logged.
        case none
        /// Some water, short of the minimum.
        case underMinimum
        /// The minimum is met, the recommended amount is not.
        case minimumMet
        /// At or over the recommended amount.
        case recommendedMet

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let ml: Int
    public let minimum: Int
    public let recommended: Int

    /// Negative totals count as none. A minimum above the recommended amount is
    /// pulled down to it, and a recommended amount below 1 ml is raised to 1, so
    /// the fractions can never divide by zero or exceed one.
    public init(
        ml: Int,
        minimum: Int = WaterAmount.defaultMinimum,
        recommended: Int = WaterAmount.defaultRecommended
    ) {
        self.ml = max(ml, 0)
        self.recommended = max(recommended, 1)
        self.minimum = min(max(minimum, 0), self.recommended)
    }

    /// Progress toward the recommended amount, 0...1. Stops at 1 however far over.
    public var fraction: Double { min(Double(ml) / Double(recommended), 1) }

    /// Where the minimum sits along the same 0...1 scale, for a marker.
    public var minimumFraction: Double { Double(minimum) / Double(recommended) }

    public var isMinimumMet: Bool { ml >= minimum && ml > 0 }
    public var isRecommendedMet: Bool { ml >= recommended }

    /// Millilitres still to drink to reach the recommended amount; 0 once met.
    public var remaining: Int { max(recommended - ml, 0) }

    public var stage: Stage {
        if ml == 0 { return .none }
        if isRecommendedMet { return .recommendedMet }
        if isMinimumMet { return .minimumMet }
        return .underMinimum
    }
}
