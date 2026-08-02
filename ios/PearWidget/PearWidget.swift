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

// ConnectionEntity and ConnectionQuery moved to PeardCore, so the Shortcuts
// action in the app target offers the same connections this sheet does rather
// than growing a second, drifting copy. The type name is unchanged, which is
// what a widget already pinned to a connection resolves through.

// MARK: - Timeline
//
// LogMomentIntent — the quick-send App Intent behind every button below —
// lives in PeardCore now, shared with the main app target's Siri/Shortcuts
// exposure (see PeardShortcuts.swift and LogBuiltinMomentIntent).

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
    /// Moments waiting in this connection that the user has not opened the app
    /// to see. The widget was the one surface that could not say whether what it
    /// was showing was new.
    let unreadCount: Int

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
        pendingLog: nil,
        unreadCount: 0
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
                pendingLog: (pending?.isFresh == true && pending?.pairID == resolvedPairID) ? pending : nil,
                unreadCount: feed.unreadCount
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
        // Top-trailing, matching the connection rail in the app, so the same
        // signal is in the same place on both surfaces.
        .overlay(alignment: .topTrailing) {
            if entry.unreadCount > 0 {
                unreadBadge
            }
        }
        .containerBackground(PearColor.background, for: .widget)
    }

    /// A dot with a count, drawn small: the widget is already dense, and the
    /// question it answers here is only "is what I am looking at new".
    ///
    /// Not applied to the `.unpaired` state, which has no connection to count
    /// for — the overlay sits outside that branch because `entry.unreadCount` is
    /// zero there anyway, and an extra condition would state the same thing
    /// twice.
    private var unreadBadge: some View {
        Text(entry.unreadCount > 9 ? "9+" : "\(entry.unreadCount)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(PearColor.onAccent)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(PearColor.accent, in: Capsule())
            .accessibilityLabel(
                entry.unreadCount == 1 ? "1 new moment" : "\(entry.unreadCount) new moments"
            )
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
            photoContent(image)
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

    // MARK: Photo

    /// A shared photo, laid out for the space there actually is.
    ///
    /// The medium family is roughly three times as wide as the moment area is
    /// tall, and the photo arrives as a 512-square thumbnail. Drawing one into
    /// the other left the picture letterboxed with black down both sides — a
    /// square in a letterbox, which is what a real device showed. Squares belong
    /// beside text, not stretched across it, so medium puts the photo in a
    /// square tile on the leading edge and gives the rest of the width to who
    /// sent it, what they said, when, and today's tallies.
    ///
    /// Small has no room for a column beside anything, so the photo takes the
    /// whole area and the words sit over it.
    @ViewBuilder
    private func photoContent(_ image: UIImage) -> some View {
        if family == .systemSmall {
            photoTile(image)
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attribution).font(.caption2).bold().lineLimit(1)
                        talliesRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                    .background(.ultraThinMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            HStack(alignment: .top, spacing: 10) {
                photoTile(image)
                    // Square, driven by the height available, so the tile is
                    // exactly the thumbnail's own shape and nothing is bordered
                    // or stretched to make it fit.
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                photoCaption
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The image, filling whatever box it is given.
    ///
    /// Drawn as an overlay on `Color.clear` rather than framed directly:
    /// `Color.clear` accepts any size proposed to it, so the image is scaled to
    /// a box the layout has already decided on. An `Image` with
    /// `.frame(maxWidth: .infinity)` negotiates its own size instead, which is
    /// how a square thumbnail ended up fitted into a wide widget with bars
    /// rather than filling it.
    private func photoTile(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .accessibilityLabel("Latest photo from \(attribution)")
    }

    /// What the medium family puts beside the photo. Everything is optional
    /// except who it was from, so a moment with no note and no tallies still
    /// reads as a sentence rather than leaving a gap.
    private var photoCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(attribution)
                .font(.caption).bold()
                .lineLimit(1)
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.caption2)
                    .foregroundStyle(PearColor.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if let created = entry.created {
                Text(created, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)
            }
            Spacer(minLength: 0)
            talliesRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Lock Screen

/// The accessory families: Lock Screen, and the Smart Stack in StandBy.
///
/// Deliberately not the home-screen view drawn smaller. These render desaturated
/// and vibrant — a solid background paints a grey slab, an accent colour is
/// flattened to luminance, and a photo becomes a smudge — so this view sets no
/// colours of its own and shows no image. It also has no buttons: a target that
/// small on a locked screen is a mis-tap, and everything here opens the app
/// instead.
///
/// What survives the cut is decided in `LockScreenSummary`, which is in
/// PeardCore because this target cannot host tests.
struct PearAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: PearEntry

    private var summary: LockScreenSummary {
        LockScreenSummary(
            state: entry.state,
            partnerName: entry.partnerName,
            groupName: entry.groupName,
            emoji: entry.emoji,
            momentLabel: entry.momentLabel,
            note: entry.note,
            tallies: entry.tallies,
            created: entry.created
        )
    }

    var body: some View {
        content
            .widgetURL(URL(string: "peard://home"))
            // Required of every widget on iOS 17, but it must not paint: the
            // Lock Screen supplies its own material behind the accessory
            // families, and anything opaque here sits on top of it.
            .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: Text(summary.inlineText)
        default: rectangular
        }
    }

    /// Roughly three short lines. The note earns the middle one; the tallies get
    /// the last only when there are any, so a quiet day does not draw an empty
    /// row where the note would have been.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(summary.emoji)
                Text(summary.headline)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let at = summary.at {
                    Text(at, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Relative time grows as it ages ("3 min" becomes
                        // "2 hours"); without this the name loses the room.
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
            }
            if let tallies = summary.talliesText {
                Text(tallies)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One emoji and one number: what happened last, and how much has happened
    /// today. Anything else at this size is unreadable.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(summary.emoji)
                    .font(.system(size: 20))
                if summary.todayTotal > 0 {
                    Text("\(summary.todayTotal)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            summary.todayTotal > 0
                ? "\(summary.headline), \(summary.todayTotal) today"
                : summary.headline
        )
    }
}

/// Picks the view for the family, so the home-screen layout never has to reason
/// about the Lock Screen and vice versa.
struct PearWidgetRootView: View {
    @Environment(\.widgetFamily) private var family

    let entry: PearEntry

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            PearAccessoryView(entry: entry)
        default:
            PearWidgetEntryView(entry: entry)
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
            PearWidgetRootView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("The latest moment from your people, today's tallies, and one-tap moments.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

@main
struct PearWidgetBundle: WidgetBundle {
    var body: some Widget {
        PearWidget()
    }
}
