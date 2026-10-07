import Foundation

/// The size of a water moment, in whole millilitres.
///
/// Millilitres is the canonical unit and the only one stored or sent. What a
/// reader sees can be fluid ounces instead (#324, `WaterUnit`); every formatter
/// and parser here that takes a unit converts at the edge and leaves the stored
/// amount alone.
///
/// Water is an ordinary moment that carries one more fact. This is the little
/// that is specific to it: the two sizes offered with a tap, what a typed size
/// may be, and how a total reads. Everything else — posting, queueing, tallying —
/// is the moment pipeline unchanged.
public enum WaterAmount {
    /// A size offered as a chip.
    public struct Preset: Hashable, Sendable, Identifiable {
        public let ml: Int
        public let name: String

        public var id: Int { ml }

        /// "330 ml (glass)", or just "250 ml" for a size with no name.
        public var label: String { label(in: .millilitres) }

        /// The same chip in the reader's unit: "11.2 fl oz (glass)". The size is
        /// still `ml`; only the words change.
        public func label(in unit: WaterUnit, locale: Locale = .current) -> String {
            let size = WaterAmount.label(ml, unit: unit, locale: locale)
            return name.isEmpty ? size : "\(size) (\(name))"
        }
    }

    /// The chip for a size: the built-in glass and bottle keep their names, anything
    /// else a connection adds (#322) is just its size.
    public static func preset(ml: Int) -> Preset {
        presets.first { $0.ml == ml } ?? Preset(ml: ml, name: "")
    }

    public static let glass = Preset(ml: 330, name: "glass")
    public static let bottle = Preset(ml: 500, name: "bottle")
    public static let presets: [Preset] = [glass, bottle]

    /// Matches the server's ceiling on `amount`. Five litres in one go is a typo.
    public static let maximum = 5000

    /// Built-in daily targets in millilitres, used until a connection can set its
    /// own (#322) in `WaterConfig`. The minimum is the least worth reaching in a day; the
    /// recommended amount is the figure to aim for.
    public static let defaultMinimum = 1500
    public static let defaultRecommended = 2000

    /// An amount worth keeping: positive, and no more than `maximum`. Anything
    /// else is `nil`, which is also what the server's 0 for "none" becomes.
    public static func normalised(_ ml: Int?) -> Int? {
        guard let ml, ml > 0, ml <= maximum else { return nil }
        return ml
    }

    /// A typed size, or `nil` when it is not a whole number in range. Digits only:
    /// a decimal point or a unit would be a guess about what was meant.
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber) else { return nil }
        return normalised(Int(trimmed))
    }

    /// A typed size in `unit`, as canonical millilitres, or `nil` when it is not a
    /// whole number that ends up in range. Whole fluid ounces, like whole
    /// millilitres: a decimal point would be a guess, and "12" in ounces is
    /// the common case (355 ml). Nothing is stored in ounces; this is the way back.
    public static func parse(_ text: String, unit: WaterUnit) -> Int? {
        switch unit {
        case .millilitres:
            return parse(text)
        case .fluidOunces:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
                  let ounces = Int(trimmed) else { return nil }
            return normalised(unit.ml(fromDisplayed: Double(ounces)))
        }
    }

    /// "1,330 ml", grouped for the reader's locale; in fluid ounces, "45 fl oz"
    /// or "11.2 fl oz" (a tenth, a trailing ".0" dropped).
    public static func label(_ ml: Int, unit: WaterUnit = .millilitres, locale: Locale = .current) -> String {
        "\(number(ml, unit: unit, locale: locale)) \(unit.symbol)"
    }

    /// "1,330 ml today".
    public static func todayLabel(_ ml: Int, unit: WaterUnit = .millilitres, locale: Locale = .current) -> String {
        "\(label(ml, unit: unit, locale: locale)) today"
    }

    /// Just the figure, with no symbol: what a text field or stepper shows beside
    /// a unit of its own.
    public static func number(_ ml: Int, unit: WaterUnit = .millilitres, locale: Locale = .current) -> String {
        switch unit {
        case .millilitres:
            return ml.formatted(.number.locale(locale))
        case .fluidOunces:
            return unit.displayed(ml: ml).formatted(.number.locale(locale).precision(.fractionLength(0...1)))
        }
    }
}
