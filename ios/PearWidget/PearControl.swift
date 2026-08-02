import AppIntents
import PeardCore
import SwiftUI
import WidgetKit

// Control Centre.
//
// The shortest route to logging that iOS offers: swipe down, tap, done —
// from any app, and from the Lock Screen without unlocking. It is also
// assignable to the Action button on the phones that have one, which makes
// logging a beer a physical button press.
//
// Three controls rather than one with a picker, because a control is a single
// tap and a picker would make it two. They are separate so somebody can put
// only the one they actually use in Control Centre.
//
// iOS 18 only. The deployment target is 17, so the whole bundle entry is
// gated — a widget bundle may contain controls conditionally, and an older
// device simply never sees them.

@available(iOS 18.0, *)
struct LogBeerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.peard.app.control.beer") {
            ControlWidgetButton(action: LogMomentIntent(
                kind: .beer, pairID: nil, emoji: "🍺", label: "Beer"
            )) {
                Label("Beer", systemImage: "mug.fill")
            }
        }
        .displayName("Log a Beer")
        .description("Logs a beer in your liveliest Pear'd connection.")
    }
}

@available(iOS 18.0, *)
struct LogCoffeeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.peard.app.control.coffee") {
            ControlWidgetButton(action: LogMomentIntent(
                kind: .coffee, pairID: nil, emoji: "☕", label: "Coffee"
            )) {
                Label("Coffee", systemImage: "cup.and.saucer.fill")
            }
        }
        .displayName("Log a Coffee")
        .description("Logs a coffee in your liveliest Pear'd connection.")
    }
}

@available(iOS 18.0, *)
struct LogLooControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.peard.app.control.loo") {
            ControlWidgetButton(action: LogMomentIntent(
                kind: .loo, pairID: nil, emoji: "💩", label: "Loo"
            )) {
                Label("Loo", systemImage: "toilet.fill")
            }
        }
        .displayName("Log a Loo")
        .description("Logs a loo in your liveliest Pear'd connection.")
    }
}
