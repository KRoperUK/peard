import PeardCore
import UIKit

/// The three moments on the app icon's long-press menu.
///
/// The shortest route to logging that does not need a widget on a home screen
/// or a Control Centre tile: press the icon you already have, pick, done. The
/// app does launch — a quick action always launches the app, unlike a widget
/// button — but it logs immediately and does not wait to finish drawing.
///
/// Only the three built-ins. A quick action's list is baked into Info.plist or
/// set at runtime, and either way it is fixed before anybody has chosen a
/// connection; a connection's own moments cannot be offered without knowing
/// which connection, and the built-ins are valid in all of them. That is the
/// same line `LogBuiltinMomentIntent` draws for Siri, for the same reason.
enum QuickActions {
    /// Prefix on the shortcut type, so a shortcut from another feature added
    /// later is not mistaken for a moment.
    private static let prefix = "com.peard.app.moment."

    /// Rebuilds the menu. Called on launch and on backgrounding, because the
    /// emoji come from `MomentCatalogue` and would otherwise be whatever they
    /// were when the app was installed.
    static func install(application: UIApplication = .shared) {
        application.shortcutItems = MomentCatalogue.builtin.map { moment in
            UIApplicationShortcutItem(
                type: prefix + moment.kind.rawValue,
                localizedTitle: moment.label,
                localizedSubtitle: nil,
                // A system icon rather than the emoji: iOS renders the title as
                // text and the icon as a glyph, and there is no emoji icon
                // type — putting the emoji in the title would read as
                // "☕ Coffee" in a menu that already shows an icon.
                icon: UIApplicationShortcutIcon(systemImageName: symbol(for: moment.kind)),
                userInfo: nil
            )
        }
    }

    /// The moment a shortcut asks for, or nil if it is not one of ours.
    static func moment(for item: UIApplicationShortcutItem) -> Moment? {
        guard item.type.hasPrefix(prefix) else { return nil }
        let slug = String(item.type.dropFirst(prefix.count))
        return MomentCatalogue.builtin.first { $0.kind.rawValue == slug }
    }

    private static func symbol(for kind: EventKind) -> String {
        switch kind {
        case .beer: return "mug.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .loo: return "toilet.fill"
        default: return "circle.fill"
        }
    }
}
