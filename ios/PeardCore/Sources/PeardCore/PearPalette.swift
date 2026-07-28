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
    public static let accent = named("PearAccent", light: 0x6B8E23, dark: 0x9BBF4F)
    public static let textPrimary = named("PearTextPrimary", light: 0x3B2E1A, dark: 0xF2E9D8)
    public static let textSecondary = named("PearTextSecondary", light: 0x7A6A53, dark: 0xC3B49B)
    public static let textTertiary = named("PearTextTertiary", light: 0xB3A78F, dark: 0x8C7F68)
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
