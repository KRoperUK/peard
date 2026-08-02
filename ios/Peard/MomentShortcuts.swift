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

    func perform() async throws -> some IntentResult {
        let option = MomentOption(encoded: moment)
        await MomentLogging.perform(
            kind: EventKind(rawValue: option.kind),
            // The moment's own connection, not the parameter: they agree
            // whenever the picker filled it in, and the moment is the one that
            // was actually chosen. A built-in carries none and falls through to
            // the connection, then to liveliest.
            pairID: option.pairID ?? connection?.id,
            emoji: option.emoji,
            label: option.label
        )
        return .result()
    }
}

/// One row of the Moment picker, and everything `perform()` needs to log it.
///
/// Carries its connection rather than only its kind, because the server refuses
/// a custom moment in a connection that has not published it — `isKnownKind`
/// returns 400 "that moment isn't available in this connection". An option that
/// named only the kind could be chosen in a way that could never succeed, and
/// the logging path has nowhere to report a failure.
struct MomentOption: Hashable {
    var kind: String
    var emoji: String
    var label: String
    /// The connection this option logs into, or nil for "whichever is liveliest"
    /// — only nil for the three built-ins, which every connection has.
    var pairID: String?
    /// Shown under the label when the option belongs to one connection, so two
    /// connections that both invented "Dog walk" can be told apart.
    var connectionTitle: String?

    /// A unit separator: not a character a moment label or a pair id can
    /// contain, and never seen by anybody — Shortcuts shows the title from the
    /// options provider, not this.
    private static let separator = "\u{1F}"

    /// Everything needed to log the moment, packed into the parameter's value.
    ///
    /// The emoji and label ride along rather than being looked up again at run
    /// time. They feed the widget's "logged" acknowledgement, and a custom
    /// moment's emoji is not derivable from its slug — resolving it would mean a
    /// network round trip before the badge could be drawn, which is exactly the
    /// delay the badge exists to cover.
    var encoded: String {
        [kind, emoji, label, pairID ?? ""].joined(separator: Self.separator)
    }

    init(kind: String, emoji: String, label: String, pairID: String? = nil, connectionTitle: String? = nil) {
        self.kind = kind
        self.emoji = emoji
        self.label = label
        self.pairID = pairID
        self.connectionTitle = connectionTitle
    }

    /// Reads back what `encoded` wrote.
    ///
    /// Tolerates a value that is only a kind slug, which is what a shortcut
    /// saved by an earlier build stored: logging it with a catalogue-resolved
    /// emoji beats failing outright on a shortcut somebody already had working.
    init(encoded value: String) {
        let parts = value.components(separatedBy: Self.separator)
        let slug = parts.first ?? ""
        let eventKind = EventKind(rawValue: slug)
        kind = slug
        emoji = parts.count > 1 && !parts[1].isEmpty ? parts[1] : MomentCatalogue.emoji(for: eventKind)
        label = parts.count > 2 && !parts[2].isEmpty ? parts[2] : MomentCatalogue.label(for: eventKind)
        pairID = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
        connectionTitle = nil
    }

    /// Available in every connection, so they need no pair and log into
    /// whichever is liveliest — the same fallback an unconfigured widget uses.
    static let builtins: [MomentOption] = MomentCatalogue.builtin.map {
        MomentOption(kind: $0.kind.rawValue, emoji: $0.emoji, label: $0.label)
    }

    /// The whole picker: the three built-ins once, then every moment a
    /// connection invented, each bound to the connection that has it.
    ///
    /// Built-ins are listed once and unbound rather than repeated per
    /// connection, which would turn three options into three times however many
    /// connections somebody has. They are valid everywhere, so one entry can
    /// serve all of them and take its connection from the action's own
    /// parameter.
    static func all(from connections: [(ConnectionEntity, [WidgetFeed.AvailableMoment])]) -> [MomentOption] {
        let builtinKinds = Set(MomentCatalogue.builtin.map(\.kind.rawValue))
        var options = builtins
        for (connection, moments) in connections {
            for moment in moments where !builtinKinds.contains(moment.kind.rawValue) {
                options.append(
                    MomentOption(
                        kind: moment.kind.rawValue,
                        emoji: moment.emoji,
                        label: moment.label,
                        pairID: connection.id,
                        connectionTitle: connection.title
                    )
                )
            }
        }
        return options
    }
}

/// Fills the Moment picker from every connection the user is in.
struct MomentOptionsProvider: DynamicOptionsProvider {
    /// Enough for anybody's connection list, and a stop on an accidental sweep
    /// of hundreds. Exceeding it is logged rather than silently truncated.
    static let connectionLimit = 24

    func results() async throws -> ItemCollection<String> {
        let options = await Self.load()
        return ItemCollection(sections: [
            IntentItemSection(items: options.map { option in
                IntentItem<String>(
                    option.encoded,
                    title: "\(option.emoji) \(option.label)",
                    subtitle: option.connectionTitle.map { "\($0)" }
                )
            }),
        ])
    }

    /// A failure leaves the built-ins rather than an empty picker: they work in
    /// every connection, and a picker with nothing in it reads as an app that
    /// cannot log anything.
    static func load() async -> [MomentOption] {
        let connections = (try? await MomentIntentSource.connections()) ?? []
        guard !connections.isEmpty else { return MomentOption.builtins }
        if connections.count > connectionLimit {
            NSLog("[Peard] moment picker showing %d of %d connections", connectionLimit, connections.count)
        }
        let shown = connections.prefix(connectionLimit).map(ConnectionEntity.init)

        // Fetched concurrently: one request per connection, and doing them in
        // turn is what would make this picker feel broken on a slow network.
        let fetched = await withTaskGroup(of: (String, [WidgetFeed.AvailableMoment]).self) { group in
            for connection in shown {
                group.addTask {
                    let moments = (try? await MomentIntentSource.moments(pairID: connection.id)) ?? []
                    return (connection.id, moments)
                }
            }
            var results: [String: [WidgetFeed.AvailableMoment]] = [:]
            for await (id, moments) in group { results[id] = moments }
            return results
        }

        // Stable order: the group finishes in whatever order the network
        // returns, and a picker whose rows move between openings is unusable.
        return MomentOption.all(from: shown.map { ($0, fetched[$0.id] ?? []) })
    }
}
