import AppIntents
import PeardCore

/// Exposes moment-logging to Siri and the Shortcuts app.
///
/// Two intents, for two different jobs.
///
/// `LogBuiltinMomentIntent` backs the spoken phrases. A phrase interpolating a
/// parameter needs a vocabulary Siri can match against before anything is
/// fetched, which an `AppEnum` has and a per-connection entity query does not —
/// so "Log a beer in Pear'd" is answerable without a network round trip, and
/// only the three built-ins can be spoken this way.
///
/// `LogPublishedMomentIntent` is the action people drag into a shortcut. It
/// reaches everything, including a moment a connection invented, because it can
/// ask which connection first.
///
/// Both are visible, and their titles carry the difference: "Log a Moment"
/// against "Log a Beer, Loo or Coffee". Hiding the spoken one with
/// `isDiscoverable = false` was tried and takes its App Shortcut with it — the
/// Pear'd section of the library came back with only one entry and no phrase to
/// say.
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
        AppShortcut(
            intent: LogPublishedMomentIntent(),
            // No parameter to interpolate: this one prompts. Worth having as a
            // phrase anyway — it is the entry point to a connection's own
            // moments, and asking is how a spoken shortcut reaches something
            // Siri could not have known the name of in advance.
            phrases: [
                "Log a moment in \(.applicationName)",
                "Log something in \(.applicationName)",
            ],
            shortTitle: "Log Any Moment",
            systemImageName: "list.bullet"
        )
    }
}
