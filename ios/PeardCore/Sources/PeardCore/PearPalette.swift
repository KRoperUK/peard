import SwiftUI

/// The Pear'd palette (Requirement 20.1, 20.2).
///
/// The values live in `Colors.xcassets`, which is compiled into both the app
/// and the widget extension, so `Bundle.main` resolves correctly in each.
/// Literal fallbacks keep previews and unit tests working when the catalogue
/// is not present.
public enum PearColor {
    public static let background = named("PearBackground", light: 0xFBF7EC, dark: 0x1C1810)
    public static let surface = named("PearSurface", light: 0xFFFFFF, dark: 0x2A2419)
    public static let accent = named("PearAccent", light: 0x55731C, dark: 0x9BBF4F)

    /// Whatever is drawn *on* the accent — button labels, badge counts.
    ///
    /// Not white. The dark-mode accent is a light green, and white on it
    /// measures 2.11:1 — below even the 3:1 bar for large text, on the primary
    /// button of every screen. Near-black on the same green is 8.39:1. In light
    /// mode the accent is dark and white is right, so this has to vary by
    /// scheme, which is exactly what a semantic colour is for.
    public static let onAccent = named("PearOnAccent", light: 0xFFFFFF, dark: 0x1C1810)
    public static let textPrimary = named("PearTextPrimary", light: 0x3B2E1A, dark: 0xF2E9D8)
    public static let textSecondary = named("PearTextSecondary", light: 0x7A6A53, dark: 0xC3B49B)
    public static let textTertiary = named("PearTextTertiary", light: 0x786B52, dark: 0xA2937A)
    public static let error = named("PearError", light: 0xB23A2E, dark: 0xE9705F)
    public static let divider = named("PearDivider", light: 0xE3DAC6, dark: 0x413828)

    private static func named(_ name: String, light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        if UIColor(named: name) != nil {
            return Color(name)
        }
        return Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return Color(rgb: light)
        #endif
    }
}

public extension Color {
    init(rgb value: UInt32) {
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

#if canImport(UIKit)
import UIKit

extension UIColor {
    convenience init(rgb value: UInt32) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

/// Animation that honours Reduce Motion (Requirement 20.6).
public struct ReduceMotionAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let animation: Animation
    private let value: AnyHashable

    public init(animation: Animation = .easeInOut(duration: 0.2), value: AnyHashable) {
        self.animation = animation
        self.value = value
    }

    public func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

public extension View {
    /// Applies an animation unless Reduce Motion is enabled.
    func pearAnimation(value: some Hashable) -> some View {
        modifier(ReduceMotionAnimation(value: AnyHashable(value)))
    }

    /// Opacity-only transition; the system already strips it under Reduce
    /// Motion because there is no movement to remove.
    func pearTransition() -> some View {
        transition(.opacity)
    }
}

// MARK: - Measurable swatches

/// The palette's raw values, so contrast can be asserted rather than eyeballed.
///
/// `Color` gives no way back to its components without a UIKit trait
/// environment, and the palette's whole point is that it has two values per
/// name. These are those values, and they are the same literals the asset
/// catalogue holds — `named(_:light:dark:)` above falls back to exactly these
/// when an asset is missing, so a drift between the two is a drift in one file.
public extension PearColor {
    struct Swatch: Hashable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }

        /// Relative luminance, per WCAG 2.
        public var luminance: Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }
    }

    struct Swatches: Sendable {
        public let background: Swatch
        public let surface: Swatch
        public let accent: Swatch
        public let onAccent: Swatch
        public let textPrimary: Swatch
        public let textSecondary: Swatch
        public let textTertiary: Swatch
        public let error: Swatch

        /// Everything that gets drawn as words, which is what the 4.5:1 rule is
        /// about. The accent is in here because it is used as a text colour too,
        /// not only as a button fill.
        public var textColours: [(String, Swatch)] {
            [
                ("textPrimary", textPrimary),
                ("textSecondary", textSecondary),
                ("textTertiary", textTertiary),
                ("accent", accent),
                ("error", error),
            ]
        }
    }

    static func swatches(dark: Bool) -> Swatches {
        Swatches(
            background: Swatch(dark ? 0x1C1810 : 0xFBF7EC),
            surface: Swatch(dark ? 0x2A2419 : 0xFFFFFF),
            accent: Swatch(dark ? 0x9BBF4F : 0x55731C),
            onAccent: Swatch(dark ? 0x1C1810 : 0xFFFFFF),
            textPrimary: Swatch(dark ? 0xF2E9D8 : 0x3B2E1A),
            textSecondary: Swatch(dark ? 0xC3B49B : 0x7A6A53),
            textTertiary: Swatch(dark ? 0xA2937A : 0x786B52),
            error: Swatch(dark ? 0xE9705F : 0xB23A2E)
        )
    }
}
