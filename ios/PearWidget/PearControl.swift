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
// Three fixed controls, and one configurable one. None of them asks anything
// when tapped — a control is a single tap, and a picker would make it two — so
// the configurable one asks once, when it is added, which moment and which
// connection it is for. That is what reaches a custom moment, a particular
// group, and the Action button for either.
//
// The fixed three stay, under their original kinds. iOS stores a control
// somebody has placed by its `kind`, so removing one — or turning it into the
// configurable control under the same kind — would leave a blank or reset
// button in Control Centre, on the Lock Screen or on the Action button of
// everybody who set one up. They also remain the quickest to add: a beer
// needs no set-up at all.
//
// iOS 18 only. The deployment target is 17, so the whole bundle entry is
// gated — a widget bundle may contain controls conditionally, and an older
// device simply never sees them.

// MARK: - Configurable

/// What the configurable control is set to: a moment, and optionally the
/// connection a built-in moment goes to.
///
/// Parameters only; the control's tap runs `LogMomentIntent`, the same action
/// the fixed controls and the widget's buttons use, so a log from here falls
/// back to the App Group inbox with no signal exactly as they do.
///
/// Declared here rather than in PeardCore, for the reason `MomentShortcuts.swift`
/// gives: an intent linked into every target is claimed by whichever the system
/// picks. This one belongs to the widget extension, which owns the control.
@available(iOS 18.0, *)
struct ConfigureMomentControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Log a Moment"
    static var description = IntentDescription(
        "Choose which moment this control logs, and which connection a beer, loo or coffee goes to."
    )

    /// The same encoded string, from the same options, as the Shortcuts
    /// action's Moment — see `LogPublishedMomentIntent.moment` for why it is not
    /// an entity. Optional so the control can be shown before it is set up.
    @Parameter(title: "Moment", optionsProvider: ControlMomentOptionsProvider())
    var moment: String?

    /// Only used by a built-in moment: a custom one already names its own.
    /// Empty means whichever connection is liveliest.
    @Parameter(title: "Connection")
    var connection: ConnectionEntity?

    init() {}
}

/// The Shortcuts picker's options, served from the widget extension.
@available(iOS 18.0, *)
struct ControlMomentOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        await MomentOption.pickerItems()
    }
}

@available(iOS 18.0, *)
struct LogMomentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.peard.app.control.moment",
            intent: ConfigureMomentControlIntent.self
        ) { configuration in
            let option = MomentOption(storedOrDefault: configuration.moment)
            let pairID = option.pairID(fallingBackTo: configuration.connection?.id)
            ControlWidgetButton(action: LogMomentIntent(
                kind: EventKind(rawValue: option.kind),
                pairID: pairID,
                emoji: option.emoji,
                label: option.label
            )) {
                Label {
                    Text("\(option.emoji) \(option.label)")
                    // Only when the connection it names is where the log goes.
                    // A custom moment chosen alongside a different connection
                    // still logs into its own, and saying otherwise would lie.
                    if let connection = configuration.connection, connection.id == pairID {
                        Text(connection.title)
                    }
                } icon: {
                    Image(systemName: Self.symbol(for: option.kind))
                }
            }
        }
        .displayName("Log a Moment")
        .description("Logs any moment — including your connections' own — in the connection you choose.")
        // Asks for the moment as the control is added, rather than leaving
        // somebody with a beer button they did not choose.
        .promptsForUserConfiguration()
    }

    /// A control's icon has to be a symbol, and a custom moment only has an
    /// emoji, so those share one; the emoji is in the title beside it.
    private static func symbol(for kind: String) -> String {
        switch kind {
        case EventKind.beer.rawValue: return "mug.fill"
        case EventKind.coffee.rawValue: return "cup.and.saucer.fill"
        case EventKind.loo.rawValue: return "toilet.fill"
        default: return "sparkles"
        }
    }
}

// MARK: - Fixed

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
