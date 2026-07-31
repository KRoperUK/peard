import AppIntents
import PeardCore
import SwiftUI
import WidgetKit

// The home-screen widget.
//
// Two things it can do that a static widget could not:
//
//  1. Log a moment without opening the app, via App Intents (iOS 17+). That is
//     the conclusion of the quick-send work — the whole premise is that a moment
//     costs one tap, and going through a cold launch to get there was three.
//  2. Be pinned to a particular connection. A user may belong to 20 and the
//     widget has room for one; before this the server always chose, which is
//     right by default and wrong as soon as somebody has a preference.
//
// Authentication is the revocable widget token in the App Group container, not the
// PocketBase session: the extension cannot read the Keychain, and the alternative
// — a keychain access group so it could — is a far wider grant than "let the
// widget log a beer".

// MARK: - Configuration

/// Which connection the widget shows, chosen in the widget's own edit sheet.
struct SelectConnectionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a connection"
    static var description = IntentDescription(
        "Pick which connection this widget follows, or leave it on Automatic to follow whichever is liveliest."
    )

    @Parameter(title: "Connection")
    var connection: ConnectionEntity?

    init() {}

    init(connection: ConnectionEntity?) {
        self.connection = connection
    }
}

/// A connection as the configuration picker sees it.
struct ConnectionEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Connection"
    static var defaultQuery = ConnectionQuery()

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

/// Supplies the picker's options from the server, using the widget token.
struct ConnectionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ConnectionEntity] {
        let all = try await suggestedEntities()
        // Preserve the order the caller asked in, and silently drop a connection
        // that has gone — a widget configured for a group the user has left must
        // fall back to Automatic rather than fail to render.
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        let store = SharedStore.shared
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else { return [] }

        let connections = try await APIClient(baseURL: baseURL).widgetConnections(token: token)
        return connections.map {
            ConnectionEntity(id: $0.id, title: $0.title, subtitle: $0.subtitle)
        }
    }
}

// MARK: - Quick-send intent

/// Logs a moment from a widget button.
///
/// No three-second window here: on the home screen that window exists so a note
/// can be typed, and there is nowhere to type one from a widget. A tap is the whole
/// gesture, so it commits immediately.
struct LogMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a moment"
    static var description = IntentDescription("Logs a moment in a Pear'd connection.")
    /// Keeps the app closed: the point is logging without a launch.
    static var openAppWhenRun = false

    @Parameter(title: "Moment")
    var kind: String

    @Parameter(title: "Connection")
    var pairID: String?

    @Parameter(title: "Emoji")
    var emoji: String

    @Parameter(title: "Label")
    var label: String

    init() {}

    init(kind: EventKind, pairID: String?, emoji: String, label: String) {
        self.kind = kind.rawValue
        self.pairID = pairID
        self.emoji = emoji
        self.label = label
    }

    func perform() async throws -> some IntentResult {
        let store = SharedStore.shared
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else {
            // Not signed in: nothing to do, and no way to say so from a widget
            // button. Reloading gets the timeline back to its "pear up" state.
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        // Shows an immediate "logged" acknowledgement (see PearEntry.pendingLog)
        // before the round trip below even starts — otherwise the only sign of
        // life is the tallies changing once the real fetch lands, which on a
        // slow connection reads as a button that did nothing.
        store.pendingWidgetLog = PendingWidgetLog(pairID: pairID, emoji: emoji, label: label, at: Date())
        WidgetCenter.shared.reloadAllTimelines()

        let api = APIClient(baseURL: baseURL)
        do {
            try await api.logWidgetMoment(token: token, kind: EventKind(rawValue: kind), pairID: pairID)
        } catch {
            // A failed tap is not worth an error dialog over a home-screen button.
            // The reload below redraws from the server, so the widget never shows a
            // moment that did not land.
        }
        store.pendingWidgetLog = nil
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Timeline

struct PearEntry: TimelineEntry {
    let date: Date
    let state: FeedState
    let partnerName: String
    /// Set only when the moment came from a named group.
    let groupName: String?
    let note: String
    let emoji: String
    let momentLabel: String
    let created: Date?
    let tallies: [WidgetFeed.Tally]
    let image: UIImage?
    /// Which connection this entry is for, so the buttons log into the same one
    /// the entry is showing.
    let pairID: String?
    /// What the buttons offer.
    let moments: [WidgetFeed.AvailableMoment]
    /// A moment fired from this widget's own buttons in the last few seconds,
    /// shown as an immediate acknowledgement while the real fetch is in flight.
    let pendingLog: PendingWidgetLog?

    /// Rendered when the credentials are missing or the request fails
    /// (Requirement 17.4, 17.5).
    static let placeholder = PearEntry(
        date: Date(),
        state: .empty,
        partnerName: PartnerLabel.fallback,
        groupName: nil,
        note: "",
        emoji: MomentCatalogue.fallbackEmoji,
        momentLabel: "",
        created: nil,
        tallies: [],
        image: nil,
        pairID: nil,
        moments: MomentCatalogue.builtin.map {
            WidgetFeed.AvailableMoment(kind: $0.kind, emoji: $0.emoji, label: $0.label)
        },
        pendingLog: nil
    )
}

struct PearTimelineProvider: AppIntentTimelineProvider {
    /// Fallback refresh cadence (Requirement 17.11); the app also calls
    /// `reloadAllTimelines()` after new posts, and so does every widget button.
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> PearEntry { .placeholder }

    func snapshot(for configuration: SelectConnectionIntent, in context: Context) async -> PearEntry {
        await loadEntry(pairID: configuration.connection?.id)
    }

    func timeline(for configuration: SelectConnectionIntent, in context: Context) async -> Timeline<PearEntry> {
        let entry = await loadEntry(pairID: configuration.connection?.id)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshInterval)))
    }

    private func loadEntry(pairID: String?) async -> PearEntry {
        let store = SharedStore.shared
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else {
            return .placeholder
        }

        do {
            let feed = try await APIClient(baseURL: baseURL).widgetFeed(token: token, pairID: pairID)
            // The configured pair when there is one, else whichever the server
            // chose — so a button logs into the connection on screen.
            let resolvedPairID = pairID ?? feed.connection?.id
            let pending = store.pendingWidgetLog
            return PearEntry(
                date: Date(),
                state: feed.state,
                partnerName: feed.partnerName,
                groupName: feed.groupName,
                note: feed.post?.displayNote ?? "",
                emoji: feed.post?.displayEmoji ?? MomentCatalogue.fallbackEmoji,
                momentLabel: feed.post?.displayLabel ?? "",
                created: feed.post?.created ?? nil,
                tallies: feed.displayTallies,
                image: await image(for: feed),
                pairID: resolvedPairID,
                moments: feed.buttonMoments,
                pendingLog: (pending?.isFresh == true && pending?.pairID == resolvedPairID) ? pending : nil
            )
        } catch {
            return .placeholder
        }
    }

    private func image(for feed: WidgetFeed) async -> UIImage? {
        guard
            let post = feed.post, post.hasMedia,
            let mediaURL = post.mediaURL,
            let url = URL(string: mediaURL),
            let data = try? await APIClient.data(from: url)
        else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Views

struct PearWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: PearEntry

    /// In a group the name matters as much as the person, so both are shown.
    private var attribution: String {
        guard let groupName = entry.groupName else { return entry.partnerName }
        return "\(entry.partnerName) · \(groupName)"
    }

    var body: some View {
        Group {
            switch entry.state {
            case .unpaired:
                Text("🍐\nPear up to get started")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            case .empty:
                emptyState
            default:
                paired
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PearColor.textPrimary)
        .containerBackground(PearColor.background, for: .widget)
    }

    /// Even with nothing to show, the buttons are worth having: logging the first
    /// moment is exactly what this state needs.
    private var emptyState: some View {
        VStack(spacing: 6) {
            if let pendingLog = entry.pendingLog {
                pendingBadge(for: pendingLog)
            } else {
                Text("Waiting for \(entry.partnerName)'s first pear…")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            momentButtons
        }
        .padding(8)
    }

    private var paired: some View {
        VStack(spacing: 6) {
            // Only the moment area opens the app; the buttons must stay tappable,
            // and a widgetURL on the whole widget would swallow them.
            Link(destination: URL(string: "peard://home")!) {
                if let pendingLog = entry.pendingLog {
                    pendingBadge(for: pendingLog)
                } else {
                    content
                }
            }
            momentButtons
        }
        .padding(8)
    }

    /// Stands in for the usual content for the few seconds between a widget
    /// button tap and the real, server-confirmed refresh — see
    /// `PendingWidgetLog`. Without this the only feedback a tap gets is the
    /// tallies eventually changing, which looks identical to a tap that
    /// silently failed until that happens.
    private func pendingBadge(for pendingLog: PendingWidgetLog) -> some View {
        VStack(spacing: 4) {
            Text(pendingLog.emoji).font(.title)
            Text("Logged \(pendingLog.label)")
                .font(.caption2.bold())
                .foregroundStyle(PearColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Logged \(pendingLog.label)")
    }

    @ViewBuilder
    private var content: some View {
        if let image = entry.image {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityLabel("Latest photo from \(attribution)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(attribution).font(.caption).bold().lineLimit(1)
                    talliesRow
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 4) {
                Text(entry.emoji)
                    .font(.title)
                    .accessibilityLabel(entry.momentLabel)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption2).lineLimit(2)
                }
                if entry.groupName != nil {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundStyle(PearColor.textSecondary)
                        .lineLimit(1)
                }
                talliesRow
                if let created = entry.created {
                    Text(created, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(PearColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Requirement 17.10 — today's tallies, whichever kinds they turned out to
    /// be. Capped so a connection with a long catalogue cannot overflow the
    /// small family.
    @ViewBuilder
    private var talliesRow: some View {
        let shown = entry.tallies.prefix(3)
        if !shown.isEmpty {
            Text(shown.map { "\($0.emoji) \($0.count)" }.joined(separator: "   "))
                .font(.caption2)
                .foregroundStyle(PearColor.textSecondary)
                .accessibilityLabel(
                    shown.map { "\($0.count) \($0.label)" }.joined(separator: ", ") + " today"
                )
        }
    }

    /// One tap per moment, straight from the home screen.
    ///
    /// The small family fits three; medium fits more but is still capped, because
    /// a row of tiny targets is worse than a short row of usable ones.
    private var momentButtons: some View {
        let limit = family == .systemSmall ? 3 : 5
        return HStack(spacing: 6) {
            ForEach(entry.moments.prefix(limit)) { moment in
                Button(intent: LogMomentIntent(kind: moment.kind, pairID: entry.pairID, emoji: moment.emoji, label: moment.label)) {
                    Text(moment.emoji)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.plain)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Log \(moment.label)")
            }
        }
    }
}

// MARK: - Widget

struct PearWidget: Widget {
    let kind = "PearWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectConnectionIntent.self,
            provider: PearTimelineProvider()
        ) { entry in
            PearWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("The latest moment from your people, today's tallies, and one-tap moments.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PearWidgetBundle: WidgetBundle {
    var body: some Widget {
        PearWidget()
    }
}
