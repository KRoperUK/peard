import AppIntents
import Foundation

/// One row of the Moment picker, and everything needed to log it.
///
/// Carries its connection rather than only its kind, because the server refuses
/// a custom moment in a connection that has not published it — `isKnownKind`
/// returns 400 "that moment isn't available in this connection". An option that
/// named only the kind could be chosen in a way that could never succeed, and
/// the logging path has nowhere to report a failure.
///
/// Moved here from the app target so the Shortcuts action and the configurable
/// Control Centre control, which lives in the widget extension, offer the same
/// moments and store them the same way. Only the value type and its loading
/// moved: each target keeps its own options provider, because the intent that
/// names a provider must be declared in exactly one target (see
/// `MomentShortcuts.swift` for what happened when it was not).
public struct MomentOption: Hashable, Sendable {
    public var kind: String
    public var emoji: String
    public var label: String
    /// The connection this option logs into, or nil for "whichever is liveliest"
    /// — only nil for the three built-ins, which every connection has.
    public var pairID: String?
    /// Shown under the label when the option belongs to one connection, so two
    /// connections that both invented "Dog walk" can be told apart.
    public var connectionTitle: String?

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
    public var encoded: String {
        [kind, emoji, label, pairID ?? ""].joined(separator: Self.separator)
    }

    public init(kind: String, emoji: String, label: String, pairID: String? = nil, connectionTitle: String? = nil) {
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
    public init(encoded value: String) {
        let parts = value.components(separatedBy: Self.separator)
        let slug = parts.first ?? ""
        let eventKind = EventKind(rawValue: slug)
        kind = slug
        emoji = parts.count > 1 && !parts[1].isEmpty ? parts[1] : MomentCatalogue.emoji(for: eventKind)
        label = parts.count > 2 && !parts[2].isEmpty ? parts[2] : MomentCatalogue.label(for: eventKind)
        pairID = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
        connectionTitle = nil
    }

    /// The option a stored value names, or the first built-in when there is
    /// none.
    ///
    /// For the configurable control, whose moment is optional so the system can
    /// show the control before anybody has set it up. A control has to do
    /// *something* when tapped, and a beer is what the three fixed controls
    /// already taught people to expect — logging nothing, silently, would read
    /// as a broken button.
    public init(storedOrDefault value: String?) {
        if let value, !value.isEmpty {
            self.init(encoded: value)
        } else {
            self = Self.builtins[0]
        }
    }

    /// The connection a log of this option goes to.
    ///
    /// The option's own connection wins over the one chosen beside it: they
    /// agree whenever the picker filled both in, and the moment is the one that
    /// was actually chosen — a custom moment sent anywhere else is refused. A
    /// built-in carries none and falls through to `connectionID`, then to nil,
    /// which the server reads as the liveliest connection.
    public func pairID(fallingBackTo connectionID: String?) -> String? {
        pairID ?? connectionID
    }

    /// Available in every connection, so they need no pair and log into
    /// whichever is liveliest — the same fallback an unconfigured widget uses.
    public static let builtins: [MomentOption] = MomentCatalogue.builtin.map {
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
    public static func all(from connections: [(ConnectionEntity, [WidgetFeed.AvailableMoment])]) -> [MomentOption] {
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

    // MARK: Loading

    /// Enough for anybody's connection list, and a stop on an accidental sweep
    /// of hundreds. Exceeding it is logged rather than silently truncated.
    public static let connectionLimit = 24

    /// What an options provider hands the system: every option, titled with its
    /// emoji and label and subtitled with its connection when it has one.
    public static func pickerItems() async -> IntentItemCollection<String> {
        let options = await load()
        return IntentItemCollection(sections: [
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
    ///
    /// One request. This used to be one per connection — a whole feed, tallies
    /// and latest post and all, fetched for each one just to read its catalogue
    /// out — which is why `/api/peard/widget/connections` learned `?moments=1`.
    public static func load() async -> [MomentOption] {
        let connections = (try? await MomentIntentSource.connections(withMoments: true)) ?? []
        guard !connections.isEmpty else { return builtins }
        if connections.count > connectionLimit {
            NSLog("[Peard] moment picker showing %d of %d connections", connectionLimit, connections.count)
        }
        return all(from: connections.prefix(connectionLimit).map {
            (ConnectionEntity($0), $0.moments ?? [])
        })
    }
}
