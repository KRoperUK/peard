import PeardCore
import SwiftUI
import WidgetKit

// Ported from app/targets/pear-widget/index.swift (Requirement 22.7), now
// decoding with PeardCore's WidgetFeed and reading the App Group through
// SharedStore.

struct PearEntry: TimelineEntry {
    let date: Date
    let state: FeedState
    let partnerName: String
    let note: String
    let eventKind: EventKind?
    let created: Date?
    let beer: Int
    let loo: Int
    let image: UIImage?

    /// Rendered when the credentials are missing or the request fails
    /// (Requirement 17.4, 17.5).
    static let placeholder = PearEntry(
        date: Date(),
        state: .empty,
        partnerName: PartnerLabel.fallback,
        note: "",
        eventKind: nil,
        created: nil,
        beer: 0,
        loo: 0,
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
                note: feed.post?.displayNote ?? "",
                eventKind: feed.post?.eventKind,
                created: feed.post?.created ?? nil,
                beer: feed.beerCount,
                loo: feed.looCount,
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
                    .accessibilityLabel("Latest photo from \(entry.partnerName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.partnerName).font(.caption).bold()
                    countsRow
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            }
        } else {
            VStack(spacing: 6) {
                Text(EventKindCatalogue.emoji(for: entry.eventKind))
                    .font(.largeTitle)
                    .accessibilityLabel(EventKindCatalogue.label(for: entry.eventKind))
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).lineLimit(2)
                }
                countsRow
                if let created = entry.created {
                    Text(created, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(PearColor.textSecondary)
                }
            }
            .padding(8)
        }
    }

    /// Requirement 17.10.
    private var countsRow: some View {
        Text("🍺 \(entry.beer)   💩 \(entry.loo)")
            .font(.caption2)
            .foregroundStyle(PearColor.textSecondary)
            .accessibilityLabel("\(entry.beer) beers, \(entry.loo) loo visits today")
    }
}

struct PearWidget: Widget {
    let kind = "PearWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PearTimelineProvider()) { entry in
            PearWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("Your partner's latest moment and today's tallies.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PearWidgetBundle: WidgetBundle {
    var body: some Widget {
        PearWidget()
    }
}
