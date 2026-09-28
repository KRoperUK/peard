import AppIntents
import Foundation
import WidgetKit

/// Shared by the widget's own buttons (`LogMomentIntent`, any kind — built-in
/// or a connection's custom one) and Siri/Shortcuts (`LogBuiltinMomentIntent`,
/// restricted to the three that need no per-connection lookup to offer).
///
/// No three-second window here: on the home screen that window exists so a note
/// can be typed, and there is nowhere to type one from a widget button or a
/// spoken phrase. The gesture is the whole thing, so it commits immediately.
public enum MomentLogging {
    /// What became of a log.
    public enum Outcome: Sendable, Equatable {
        /// The server took it.
        case logged
        /// It could not reach the server and is waiting in the `MomentInbox`
        /// for the app to send.
        case queued
        /// Signed out, refused by the server, or unreachable with nowhere to
        /// keep it. Nothing will arrive.
        case failed
    }

    /// Logs a moment, and reports what became of it.
    ///
    /// The result exists for the Messages extension, which — unlike a widget
    /// button or a spoken phrase — puts a message into somebody's conversation
    /// saying the moment was logged. It used to insert that bubble whether or
    /// not anything had been logged, so a tap with no signal produced a bubble
    /// asserting something untrue into a chat with another person. Siri and
    /// Shortcuts read it too, to say what happened.
    ///
    /// A failure worth retrying — no signal, a timeout, a server that is down —
    /// goes into `inbox` rather than being dropped. This used to swallow it, so
    /// the widget button on a train looked as if it had worked and nothing ever
    /// arrived. The app takes the inbox into its send queue the next time it
    /// launches or comes to the foreground. `inbox` is `nil` for the Messages
    /// extension, which has already told the person the log failed and so must
    /// not deliver it later behind their back.
    ///
    /// `store` is injected so the not-signed-in path can be tested. It defaults
    /// to the real App Group container, which is what every caller passes.
    @discardableResult
    public static func perform(
        kind: EventKind,
        pairID: String?,
        emoji: String,
        label: String,
        store: SharedStore = .shared,
        inbox: MomentInbox? = .appGroup()
    ) async -> Outcome {
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else {
            // Not signed in: nothing to do, and no way to say so from a widget
            // button. Reloading gets the timeline back to its "pear up" state.
            WidgetCenter.shared.reloadAllTimelines()
            return .failed
        }

        // Shows an immediate "logged" acknowledgement (see PearEntry.pendingLog)
        // before the round trip below even starts — otherwise the only sign of
        // life is the tallies changing once the real fetch lands, which on a
        // slow connection reads as a button that did nothing.
        let pending = PendingWidgetLog(pairID: pairID, emoji: emoji, label: label, at: Date())
        store.pendingWidgetLog = pending
        WidgetCenter.shared.reloadAllTimelines()

        // Chosen here rather than left to `logWidgetMoment`'s default so that an
        // inboxed retry carries the same id as this attempt. See `InboxedMoment.id`.
        let clientID = UUID().uuidString
        let api = APIClient(baseURL: baseURL)
        let outcome: Outcome
        do {
            try await api.logWidgetMoment(token: token, kind: kind, pairID: pairID, clientID: clientID)
            outcome = .logged
        } catch {
            // Only a failure that waiting could fix is kept. A 400 or 403 — a
            // moment the connection does not have, a connection somebody has
            // left — would fail the same way from the app.
            if let inbox, case .retryable = SendFailure.classify(error) {
                let moment = InboxedMoment(
                    id: clientID, pairID: pairID, kind: kind, emoji: emoji, label: label, queuedAt: pending.at
                )
                outcome = inbox.append(moment) ? .queued : .failed
            } else {
                outcome = .failed
            }
        }
        // Kept, not cleared: the widget shows the outcome for a few seconds and
        // schedules its own return to normal (see PendingWidgetLog).
        store.pendingWidgetLog = pending.finished(outcome.widgetOutcome)
        WidgetCenter.shared.reloadAllTimelines()
        return outcome
    }
}

extension MomentLogging.Outcome {
    var widgetOutcome: PendingWidgetLog.Outcome {
        switch self {
        case .logged: return .logged
        case .queued: return .queued
        case .failed: return .failed
        }
    }

    /// What Siri says, and Shortcuts shows, once a logging intent has run.
    ///
    /// Without one Siri answered "log a beer" with nothing to say whether it
    /// had, and on a train it had not. The emoji and label are data
    /// interpolated into a literal template, so the phrase stays translatable.
    public func dialog(emoji: String, label: String) -> IntentDialog {
        switch self {
        case .logged: return "Logged \(emoji) \(label)"
        case .queued: return "Saved — it'll send when you're back online"
        case .failed: return "Couldn't log \(emoji) \(label). Open Pear'd to try again."
        }
    }
}

/// Logs a moment from a widget button — any kind offered in the connection's
/// catalogue, built-in or custom.
///
/// Plumbing, not an action. Its parameters are the raw strings a widget button
/// already knows (a kind slug, a pair id, an emoji, a label), none of which a
/// person could sensibly fill in, and it was sitting in the Shortcuts library as
/// "Log a moment" one row above `LogPublishedMomentIntent`'s "Log a Moment" —
/// two entries a case apart, one of them unusable. `isDiscoverable` is right
/// here and wrong for the spoken intent, because this one has no App Shortcut to
/// lose.
public struct LogMomentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Log a moment"
    public static var description = IntentDescription("Logs a moment in a Pear'd connection.")
    /// Keeps the app closed: the point is logging without a launch.
    public static var openAppWhenRun = false
    public static var isDiscoverable = false

    @Parameter(title: "Moment")
    public var kind: String

    @Parameter(title: "Connection")
    public var pairID: String?

    @Parameter(title: "Emoji")
    public var emoji: String

    @Parameter(title: "Label")
    public var label: String

    public init() {}

    public init(kind: EventKind, pairID: String?, emoji: String, label: String) {
        self.kind = kind.rawValue
        self.pairID = pairID
        self.emoji = emoji
        self.label = label
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await MomentLogging.perform(
            kind: EventKind(rawValue: kind), pairID: pairID, emoji: emoji, label: label
        )
        return .result(dialog: outcome.dialog(emoji: emoji, label: label))
    }
}

/// The three moments that need no per-connection lookup to offer, so Siri can
/// speak them directly in a phrase ("Log a beer in Pear'd") instead of
/// prompting.
///
/// An `AppEnum` rather than an entity on purpose: an App Shortcut phrase needs a
/// vocabulary Siri can match against before anything is fetched, and a dynamic
/// query has none. `LogPublishedMomentIntent` covers everything else, and is
/// where custom moments live.
public enum BuiltinMomentKind: String, AppEnum {
    case beer, loo, coffee

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Moment"

    // Literal strings only: the App Intents build-time metadata extractor
    // statically analyses this initializer rather than running it, so a
    // computed value here (e.g. looking the emoji up in MomentCatalogue)
    // fails the build with "invalid segment" rather than a runtime error.
    // Keep in step with MomentCatalogue.builtin by hand.
    //
    // Synonyms are what Siri also accepts for each case: the other words
    // people use, and what speech-to-text makes of "loo" — "Lou" more often
    // than not. Adding one is safe; the raw values are the stored contract.
    public static var caseDisplayRepresentations: [BuiltinMomentKind: DisplayRepresentation] = [
        .beer: DisplayRepresentation(title: "Beer", subtitle: "🍺", synonyms: ["Beers", "Pint", "Pints"]),
        .loo: DisplayRepresentation(title: "Loo", subtitle: "💩", synonyms: ["Toilet", "Bathroom", "Lou"]),
        .coffee: DisplayRepresentation(title: "Coffee", subtitle: "☕", synonyms: ["Coffees"]),
    ]

    var eventKind: EventKind {
        switch self {
        case .beer: return .beer
        case .loo: return .loo
        case .coffee: return .coffee
        }
    }

    var descriptor: Moment { Self.descriptor(self) }

    private static func descriptor(_ kind: BuiltinMomentKind) -> Moment {
        MomentCatalogue.builtin.first { $0.kind.rawValue == kind.rawValue } ?? Moment(
            kind: kind.eventKind, emoji: MomentCatalogue.fallbackEmoji, label: kind.rawValue
        )
    }
}

/// Backs the spoken phrase in `PeardShortcuts` — "Log a beer in Pear'd".
///
/// Named for exactly what it does rather than something close to
/// `LogPublishedMomentIntent`'s "Log a Moment". Two entries under nearly the
/// same name, one of them quietly unable to log half the moments, is a trap;
/// two entries where one says which three it handles is a choice.
///
/// `isDiscoverable = false` looked like the tidier answer and was tried first.
/// It hides the intent from the Shortcuts app — and takes its App Shortcut, and
/// therefore its spoken phrases, with it. The Pear'd section of the library came
/// back with this one missing entirely.
public struct LogBuiltinMomentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Log a Beer, Loo or Coffee"
    public static var description = IntentDescription("Logs a beer, loo or coffee in your liveliest Pear'd connection.")
    public static var openAppWhenRun = false

    @Parameter(title: "Moment")
    public var kind: BuiltinMomentKind

    public init() {}

    public init(kind: BuiltinMomentKind) {
        self.kind = kind
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Log a \(\.$kind)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let descriptor = kind.descriptor
        let outcome = await MomentLogging.perform(
            kind: kind.eventKind, pairID: nil, emoji: descriptor.emoji, label: descriptor.label
        )
        return .result(dialog: outcome.dialog(emoji: descriptor.emoji, label: descriptor.label))
    }
}
