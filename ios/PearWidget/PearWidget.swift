import PeardCore
import SwiftUI
import WidgetKit

// Ported from app/targets/pear-widget/index.swift (Requirement 22.7), now
// decoding with PeardCore's WidgetFeed and reading the App Group through
// SharedStore.
//
// A user may belong to several connections and the widget has room for one, so
// the server picks whichever somebody else posted in most recently and says which
// it chose. Emoji and labels arrive resolved, so a custom moment renders here
// without the widget needing the connection's catalogue.

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
        image: nil
    )
}

struct PearTimelineProvider: TimelineProvider {
    /// Fallback refresh cadence (Requirement 17.11); the app also calls
    /// `reloadAllTimelines()` after new posts.
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> PearEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PearEntry) -> Void) {
        Task { completion(await loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PearEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            let next = Date().addingTimeInterval(Self.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> PearEntry {
        let store = SharedStore.shared
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else {
            return .placeholder
        }

        do {
            let feed = try await APIClient(baseURL: baseURL).widgetFeed(token: token)
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
                image: await image(for: feed)
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

struct PearWidgetEntryView: View {
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
                Text("Waiting for \(entry.partnerName)'s first pear…")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            default:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PearColor.textPrimary)
        .containerBackground(PearColor.background, for: .widget)
        .widgetURL(URL(string: "peard://home"))
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
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            }
        } else {
            VStack(spacing: 6) {
                Text(entry.emoji)
                    .font(.largeTitle)
                    .accessibilityLabel(entry.momentLabel)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).lineLimit(2)
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
            .padding(8)
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
}

struct PearWidget: Widget {
    let kind = "PearWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PearTimelineProvider()) { entry in
            PearWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("The latest moment from your people, and today's tallies.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PearWidgetBundle: WidgetBundle {
    var body: some Widget {
        PearWidget()
    }
}
