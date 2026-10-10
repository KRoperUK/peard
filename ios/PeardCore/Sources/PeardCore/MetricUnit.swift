import Foundation

/// How a trackable metric's amount is measured and read (#386).
///
/// A metric is a moment kind that carries an `amount` toward a daily goal —
/// water is the built-in hero, but steps, exercise minutes and the like fit the
/// same shape. The amount is always stored and sent as one canonical whole
/// number (millilitres for water, steps for a step count, minutes for exercise);
/// this type converts at the edge for display and parses typed input back, so
/// the stored amount never changes with how it is shown.
///
/// Water keeps its own `WaterUnit` (ml ⇄ fl oz) for the hero's richer unit
/// switching; `MetricUnit` covers the general cases a new metric needs without
/// reaching for a bespoke unit each time.
public enum MetricUnit: String, CaseIterable, Sendable {
    /// A plain count: steps, flights, glasses-as-count. No symbol after small
    /// numbers; the label carries the noun.
    case count
    /// Whole minutes: exercise, meditation, time outside.
    case minutes
    /// Millilitres of a volume, read with `WaterUnit` for the hero.
    case millilitres

    /// What water uses, so the hero round-trips through the general type.
    public static let water = MetricUnit.millilitres

    /// The symbol written after the figure, or "" when the label carries the
    /// noun (a count reads "8,000", the kind's label says "steps").
    public var symbol: String {
        switch self {
        case .count: return ""
        case .minutes: return "min"
        case .millilitres: return "ml"
        }
    }

    /// The unit's full name, for spoken labels.
    public var spokenName: String {
        switch self {
        case .count: return "steps"
        case .minutes: return "minutes"
        case .millilitres: return "millilitres"
        }
    }

    /// The step a settings stepper moves this unit in canonical units.
    public var step: Int {
        switch self {
        case .count: return 500
        case .minutes: return 5
        case .millilitres: return WaterConfig.step
        }
    }

    /// Tolerant of an unrecognised or missing stored value: an unknown unit is a
    /// plain count, the safe general case.
    public init(storedValue: String?) {
        self = MetricUnit(rawValue: storedValue ?? "") ?? .count
    }

    /// "8,000", "30 min", "1,500 ml" — the figure in the reader's locale with
    /// the symbol, if any.
    public func label(_ amount: Int, locale: Locale = .current) -> String {
        let number = amount.formatted(.number.locale(locale))
        return symbol.isEmpty ? number : "\(number) \(symbol)"
    }

    /// A typed whole number in this unit, or nil when it is not digits in range.
    /// Digits only: a decimal point or a unit would be a guess about what was
    /// meant, the same rule `WaterAmount.parse` holds water to.
    public func parse(_ text: String, maximum: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
              let value = Int(trimmed), value > 0, value <= maximum else { return nil }
        return value
    }
}
