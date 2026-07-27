import WidgetKit
import SwiftUI

private let appGroupID = "group.com.peard.app"
private let pearCream = Color(red: 0.984, green: 0.969, blue: 0.925)

// MARK: - Feed model (mirrors GET /api/peard/widget/feed)

struct FeedResponse: Decodable {
    struct Partner: Decodable { let name: String }
    struct Counts: Decodable { let beer: Int; let loo: Int }
    struct Post: Decodable {
        let id: String
        let type: String
        let event_kind: String
        let note: String
        let created: String
        let media_url: String
    }
    let state: String
    let partner: Partner?
    let counts: Counts?
    let post: Post?
}

struct PearEntry: TimelineEntry {
    let date: Date
    let state: String
    let partnerName: String
    let note: String
    let eventKind: String
    let created: Date?
    let beer: Int
    let loo: Int
    let image: UIImage?

    static let placeholder = PearEntry(
        date: Date(), state: "empty", partnerName: "Partner",
        note: "", eventKind: "", created: nil, beer: 0, loo: 0, image: nil
    )
}

// MARK: - Timeline provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PearEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PearEntry) -> Void) {
        Task { completion(await loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PearEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            // Fallback refresh every ~15 min; silent pushes and app opens
            // call WidgetCenter.reloadAllTimelines() for fresher updates
            // (both are subject to the system's reload budget).
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> PearEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let token = defaults?.string(forKey: "widgetToken"),
              let baseURL = defaults?.string(forKey: "apiBaseUrl"),
              var components = URLComponents(string: baseURL + "/api/peard/widget/feed") else {
            return .placeholder
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return .placeholder }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let feed = try JSONDecoder().decode(FeedResponse.self, from: data)

            var image: UIImage? = nil
            if let media = feed.post?.media_url, !media.isEmpty,
               let imageURL = URL(string: media),
               let (imageData, _) = try? await URLSession.shared.data(from: imageURL) {
                image = UIImage(data: imageData)
            }

            return PearEntry(
                date: Date(),
                state: feed.state,
                partnerName: feed.partner?.name ?? "Partner",
                note: feed.post?.note ?? "",
                eventKind: feed.post?.event_kind ?? "",
                created: parsePBDate(feed.post?.created),
                beer: feed.counts?.beer ?? 0,
                loo: feed.counts?.loo ?? 0,
                image: image
            )
        } catch {
            return .placeholder
        }
    }
}

private func parsePBDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
    return formatter.date(from: value)
}

// MARK: - Views

struct PearWidgetEntryView: View {
    let entry: PearEntry

    var body: some View {
        Group {
            switch entry.state {
            case "unpaired":
                Text("🍐\nPear up to get started")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            case "empty":
                Text("Waiting for \(entry.partnerName)'s first pear…")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            default:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pearCream)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.partnerName).font(.caption).bold()
                    countsRow
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(8)
            }
        } else {
            VStack(spacing: 6) {
                Text(emoji(for: entry.eventKind)).font(.largeTitle)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).lineLimit(2)
                }
                countsRow
                if let created = entry.created {
                    Text(created, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var countsRow: some View {
        Text("🍺 \(entry.beer)   💩 \(entry.loo)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func emoji(for kind: String) -> String {
        switch kind {
        case "beer": return "🍺"
        case "loo": return "💩"
        case "coffee": return "☕"
        default: return "🍐"
        }
    }
}

// MARK: - Widget

@main
struct PearWidget: Widget {
    let kind = "PearWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PearWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("Your partner's latest moment and today's tallies.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
