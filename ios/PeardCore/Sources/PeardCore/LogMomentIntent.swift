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
    /// Logs a moment, and reports whether the server took it.
    ///
    /// The result exists for the Messages extension, which — unlike a widget
    /// button or a spoken phrase — puts a message into somebody's conversation
    /// saying the moment was logged. It used to insert that bubble whether or
    /// not anything had been logged, so a tap with no signal produced a bubble
    /// asserting something untrue into a chat with another person. Callers with
    /// nowhere to show an error still ignore it, which is what the widget and
    /// Siri do.
    /// `store` is injected so the not-signed-in path can be tested. It defaults
    /// to the real App Group container, which is what every caller passes.
    @discardableResult
    public static func perform(
        kind: EventKind,
        pairID: String?,
        emoji: String,
        label: String,
        store: SharedStore = .shared
    ) async -> Bool {
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else {
            // Not signed in: nothing to do, and no way to say so from a widget
            // button or Siri. Reloading gets the timeline back to its
            // "pear up" state.
            WidgetCenter.shared.reloadAllTimelines()
            return false
        }

        // Shows an immediate "logged" acknowledgement (see PearEntry.pendingLog)
        // before the round trip below even starts — otherwise the only sign of
        // life is the tallies changing once the real fetch lands, which on a
        // slow connection reads as a button that did nothing.
        store.pendingWidgetLog = PendingWidgetLog(pairID: pairID, emoji: emoji, label: label, at: Date())
        WidgetCenter.shared.reloadAllTimelines()

        let api = APIClient(baseURL: baseURL)
        var accepted = false
        do {
            try await api.logWidgetMoment(token: token, kind: kind, pairID: pairID)
            accepted = true
        } catch {
            // A failed tap is not worth an error dialog over a home-screen button.
            // The reload below redraws from the server, so the widget never shows a
            // moment that did not land.
        }
        store.pendingWidgetLog = nil
        WidgetCenter.shared.reloadAllTimelines()
        return accepted
    }
}

/// Logs a moment from a widget button — any kind offered in the connection's
/// catalogue, built-in or custom.
public struct LogMomentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Log a moment"
    public static var description = IntentDescription("Logs a moment in a Pear'd connection.")
    /// Keeps the app closed: the point is logging without a launch.
    public static var openAppWhenRun = false

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

    public func perform() async throws -> some IntentResult {
        await MomentLogging.perform(kind: EventKind(rawValue: kind), pairID: pairID, emoji: emoji, label: label)
        return .result()
    }
}

/// The three moments that need no per-connection lookup to offer, so Siri can
/// speak them directly in a phrase ("Log a beer in Pear'd") instead of
/// prompting. A connection's own custom moments aren't reachable this way —
/// they would need a dynamic, per-connection entity query, which needs a
/// connection chosen first. Logs into whichever connection is liveliest, the
/// same fallback the widget's own feed uses when it has not been pinned to one.
public enum BuiltinMomentKind: String, AppEnum {
    case beer, loo, coffee

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Moment"

    // Literal strings only: the App Intents build-time metadata extractor
    // statically analyses this initializer rather than running it, so a
    // computed value here (e.g. looking the emoji up in MomentCatalogue)
    // fails the build with "invalid segment" rather than a runtime error.
    // Keep in step with MomentCatalogue.builtin by hand.
    public static var caseDisplayRepresentations: [BuiltinMomentKind: DisplayRepresentation] = [
        .beer: DisplayRepresentation(title: "Beer", subtitle: "🍺"),
        .loo: DisplayRepresentation(title: "Loo", subtitle: "💩"),
        .coffee: DisplayRepresentation(title: "Coffee", subtitle: "☕"),
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

/// Logs one of the three built-in moments, exposed to Siri and the Shortcuts
/// app via `PeardShortcuts` in the main app target.
public struct LogBuiltinMomentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Log a Moment"
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

    public func perform() async throws -> some IntentResult {
        let descriptor = kind.descriptor
        await MomentLogging.perform(kind: kind.eventKind, pairID: nil, emoji: descriptor.emoji, label: descriptor.label)
        return .result()
    }
}
