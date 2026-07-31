import AppIntents
import PeardCore

/// Exposes moment-logging to Siri and the Shortcuts app.
///
/// Only the three built-ins are offered (`LogBuiltinMomentIntent`) — a
/// connection's own custom moments need a connection chosen first, which
/// needs its own entity picker; a fine follow-up, not this one. Logs into
/// whichever connection is liveliest, same as an unconfigured widget.
struct PeardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogBuiltinMomentIntent(),
            phrases: [
                "Log a \(\.$kind) in \(.applicationName)",
                "Log \(\.$kind) in \(.applicationName)",
            ],
            shortTitle: "Log a Moment",
            systemImageName: "cup.and.saucer"
        )
    }
}
