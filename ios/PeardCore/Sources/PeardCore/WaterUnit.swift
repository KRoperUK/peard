import Foundation

/// The unit water is *shown* in (#324).
///
/// Display only. Millilitres is the one canonical unit: it is what a moment
/// stores, what goes on the wire (`"amount": "<ml>"`), what the day's total is
/// summed in and what the targets and chips are kept in. This enum converts at the
/// edge — canonical ml to something to read, and something typed back to ml — so
/// switching it can never change a stored amount or a past total, only how it is
/// drawn.
///
/// A fluid ounce is the US one, 29.5735 ml. The imperial ounce (28.4131 ml) is
/// close enough to be confusing and far enough to be wrong; the US customary
/// ounce is what a US label, cup and bottle are measured in, and the US is the
/// one place this default applies.
///
/// Per user, not per connection: it is a fact about who is reading, and nobody
/// wants one group in ounces and another in millilitres.
public enum WaterUnit: String, CaseIterable, Sendable {
    case millilitres = "ml"
    case fluidOunces = "floz"

    /// Millilitres in one US fluid ounce.
    public static let mlPerFluidOunce = 29.5735

    /// US locales read in fluid ounces; everywhere else, millilitres.
    public static func `default`(for locale: Locale = .current) -> WaterUnit {
        locale.region?.identifier == "US" ? .fluidOunces : .millilitres
    }

    /// Tolerant of a value it does not recognise, or none yet: nothing stored
    /// means nobody has chosen, so the locale decides — and keeps deciding, so a
    /// phone moved to another region follows it until somebody picks.
    public init(storedValue: String?, locale: Locale = .current) {
        self = WaterUnit(rawValue: storedValue ?? "") ?? .default(for: locale)
    }

    /// "ml" or "fl oz", as written after a number.
    public var symbol: String {
        switch self {
        case .millilitres: return "ml"
        case .fluidOunces: return "fl oz"
        }
    }

    public var title: String {
        switch self {
        case .millilitres: return "Millilitres (ml)"
        case .fluidOunces: return "Fluid ounces (fl oz)"
        }
    }

    /// The unit's name in full, for spoken labels.
    public var spokenName: String {
        switch self {
        case .millilitres: return "millilitres"
        case .fluidOunces: return "fluid ounces"
        }
    }

    // MARK: Converting

    /// A stored amount as a number in this unit. Millilitres are whole; ounces
    /// are rounded to a tenth, which is finer than anybody pours and keeps a
    /// whole-ounce entry reading back as the whole ounce it was.
    public func displayed(ml: Int) -> Double {
        switch self {
        case .millilitres:
            return Double(ml)
        case .fluidOunces:
            return (Double(ml) / Self.mlPerFluidOunce * 10).rounded() / 10
        }
    }

    /// An amount typed in this unit as canonical millilitres, rounded to the
    /// nearest. Not range-checked: `WaterAmount.normalised` does that.
    public func ml(fromDisplayed value: Double) -> Int {
        switch self {
        case .millilitres: return Int(value.rounded())
        case .fluidOunces: return Int((value * Self.mlPerFluidOunce).rounded())
        }
    }

    /// The next stop for a settings stepper, in canonical millilitres: 100 ml
    /// for millilitres, as the stepper has always moved; the next multiple of
    /// 4 fl oz for ounces, because 100 ml steps read 50.7, 54.1, 57.5.
    public func stepped(_ ml: Int, up: Bool) -> Int {
        switch self {
        case .millilitres:
            return ml + (up ? WaterConfig.step : -WaterConfig.step)
        case .fluidOunces:
            let stride = Self.stepperFluidOunces
            let steps = (displayed(ml: ml) / stride * 100).rounded() / 100
            let next = up ? steps.rounded(.down) + 1 : steps.rounded(.up) - 1
            return self.ml(fromDisplayed: next * stride)
        }
    }

    /// How far a fluid-ounce stepper moves.
    static let stepperFluidOunces = 4.0
}
