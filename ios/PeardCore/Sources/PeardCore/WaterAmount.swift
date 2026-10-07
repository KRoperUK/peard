import Foundation

/// The size of a water moment, in whole millilitres.
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

        /// "330 ml (glass)".
        public var label: String { "\(WaterAmount.label(ml)) (\(name))" }
    }

    public static let glass = Preset(ml: 330, name: "glass")
    public static let bottle = Preset(ml: 500, name: "bottle")
    public static let presets: [Preset] = [glass, bottle]

    /// Matches the server's ceiling on `amount`. Five litres in one go is a typo.
    public static let maximum = 5000

    /// Built-in daily targets in millilitres, used until a connection can set its
    /// own (#322). The minimum is the least worth reaching in a day; the
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

    /// "1,330 ml", grouped for the reader's locale.
    public static func label(_ ml: Int, locale: Locale = .current) -> String {
        "\(ml.formatted(.number.locale(locale))) ml"
    }

    /// "1,330 ml today".
    public static func todayLabel(_ ml: Int, locale: Locale = .current) -> String {
        "\(label(ml, locale: locale)) today"
    }
}
