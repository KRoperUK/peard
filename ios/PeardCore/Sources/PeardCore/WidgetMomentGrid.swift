import Foundation

/// How many moment buttons the large widget draws, and in what shape
/// (issue #264).
///
/// Here rather than in the widget because that target cannot host tests.
/// Capped rather than scrolling — a widget cannot scroll — and a connection can
/// have fifty custom kinds on top of the built-ins, so the full catalogue has to
/// be cut somewhere. At the accessibility text sizes each emoji is several
/// times larger, so the grid gets fewer, wider cells instead of clipped ones.
public enum WidgetMomentGrid {
    public static func columns(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 4 : 5
    }

    public static func maxRows(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 2 : 4
    }

    /// The moments that fit, in their own order.
    public static func shown<Item>(_ moments: [Item], isAccessibilitySize: Bool) -> [Item] {
        Array(moments.prefix(columns(isAccessibilitySize: isAccessibilitySize) * maxRows(isAccessibilitySize: isAccessibilitySize)))
    }
}
