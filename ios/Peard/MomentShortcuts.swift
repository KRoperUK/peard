import AppIntents
import Foundation
import PeardCore

// The Shortcuts moment picker, and the action behind it.
//
// In the app target rather than PeardCore, which was the first place it went and
// the reason it did not work at all. PeardCore is linked into the app, the widget
// and the Messages extension, so all three declared this intent — and the system
// chose the widget extension to run it, where the action died with "an internal
// error occurred". Declared here it has exactly one home, which is the app.
//
// ConnectionEntity stays in PeardCore because the widget's configuration sheet
// genuinely needs it too.

/// Logs any moment a connection publishes, from the Shortcuts app.
///
/// The action people drag into a shortcut, and the only one that can reach a
/// moment a connection invented.
///
/// The Moment picker lists everything at once: the three built-ins, then each
/// connection's own moments labelled with the connection they belong to. A
/// custom moment therefore arrives already knowing where it goes, which it has
/// to — the server refuses a kind a connection has not published.
///
/// Connection is optional, and only bites on a built-in: those are valid
/// everywhere, so it is the only way to say which connection a beer belongs in.
/// Left empty they go to whichever connection is liveliest, the same fallback an
/// unconfigured widget uses.
struct LogPublishedMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a Moment"
    static var description = IntentDescription(
        "Logs a moment in a Pear'd connection, including the ones your connection made up."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Connection")
    var connection: ConnectionEntity?

    /// A `String` behind a dynamic options provider rather than an `AppEntity`.
    ///
    /// It was an entity first, and Shortcuts would not give it back. The picker
    /// filled correctly and the action then failed at run time with the moment
    /// nil — instrumenting the query showed why: `suggestedEntities()` ran when
    /// the picker opened, and `entities(for:)` was never called at all, so
    /// nothing ever restored the stored entity. A string has no identity to
    /// round-trip and so nothing to lose; the options provider still supplies
    /// the emoji, the label and the connection name for display.
    @Parameter(title: "Moment", optionsProvider: MomentOptionsProvider())
    var moment: String

    init() {}

    init(connection: ConnectionEntity?, moment: String) {
        self.connection = connection
        self.moment = moment
    }

    // Connection is in the trailing "when" clause rather than the sentence: the
    // common shortcut logs a moment and does not care which connection, and a
    // summary that leads with a picker somebody will leave empty reads as a
    // required choice.
    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$moment)") {
            \.$connection
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let option = MomentOption(encoded: moment)
        let outcome = await MomentLogging.perform(
            kind: EventKind(rawValue: option.kind),
            // The moment's own connection before the parameter; see
            // `MomentOption.pairID(fallingBackTo:)`.
            pairID: option.pairID(fallingBackTo: connection?.id),
            emoji: option.emoji,
            label: option.label
        )
        return .result(dialog: outcome.dialog(emoji: option.emoji, label: option.label))
    }
}

/// Fills the Moment picker from every connection the user is in.
///
/// The options themselves, and how they are fetched, are `MomentOption`'s in
/// PeardCore — shared with the configurable Control Centre control, which needs
/// the same list from the widget extension. The provider stays here so the
/// intent above and the provider it names are declared in the same one target.
struct MomentOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        await MomentOption.pickerItems()
    }
}
