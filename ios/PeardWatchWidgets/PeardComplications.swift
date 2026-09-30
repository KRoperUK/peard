import PeardCore
import SwiftUI
import WidgetKit

/// Watch-face complications (issue #8): the latest moment and today's count,
/// from the same feed and the same `LockScreenSummary` as the iPhone's Lock
/// Screen widgets, which were already the right shape for a watch face.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let summary: LockScreenSummary

    static let placeholder = ComplicationEntry(
        date: Date(),
        summary: LockScreenSummary(state: .empty, partnerName: PartnerLabel.fallback, emoji: MomentCatalogue.fallbackEmoji)
    )
    static let signedOut = ComplicationEntry(
        date: Date(),
        summary: LockScreenSummary(state: .unpaired, partnerName: "", emoji: "")
    )
}

struct ComplicationProvider: TimelineProvider {
    /// Complications get a small refresh budget; the watch app asks for a
    /// reload whenever a moment is logged, so this is only the fallback.
    static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> ComplicationEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        Task { completion(await Self.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        Task {
            let entry = await Self.load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshInterval))))
        }
    }

    private static func load() async -> ComplicationEntry {
        let store = SharedStore.shared
        guard let credentials = WatchCredentials(store: store) else { return .signedOut }
        guard let feed = try? await APIClient(baseURL: credentials.baseURL).widgetFeed(
            token: credentials.token,
            pairID: store.selectedConnectionID
        ) else { return .placeholder }
        return ComplicationEntry(date: Date(), summary: LockScreenSummary(
            state: feed.state,
            partnerName: feed.partnerName,
            groupName: feed.groupName,
            emoji: feed.post?.displayEmoji ?? MomentCatalogue.fallbackEmoji,
            momentLabel: feed.post?.displayLabel ?? "",
            note: feed.post?.displayNote ?? "",
            tallies: feed.displayTallies,
            created: feed.post?.happenedOrCreated
        ))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    private var summary: LockScreenSummary { entry.summary }

    var body: some View {
        content.containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text(summary.inlineText)
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            Text(summary.emoji)
                .font(.title3)
                .widgetLabel(summary.todayTotal > 0 ? "\(summary.todayTotal) today" : summary.headline)
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(summary.emoji)
                Text(summary.headline)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let detail = summary.detail {
                Text(detail).font(.caption).lineLimit(1)
            }
            if let tallies = summary.talliesText {
                Text(tallies).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(summary.emoji).font(.system(size: 18))
                if summary.todayTotal > 0 {
                    Text("\(summary.todayTotal)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.todayTotal > 0 ? "\(summary.headline), \(summary.todayTotal) today" : summary.headline)
    }
}

@main
struct PeardComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeardComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("The latest moment and today's count.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
