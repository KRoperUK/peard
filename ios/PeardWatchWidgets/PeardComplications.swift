import PeardCore
import SwiftUI
import WidgetKit

/// Watch-face complications (issue #8): the latest moment and today's count,
/// from the same feed and the same `LockScreenSummary` as the iPhone's Lock
/// Screen widgets, which were already the right shape for a watch face.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let summary: LockScreenSummary

    /// The rectangular family is also the watchOS Smart Stack widget (issue
    /// #287), and this is what lets the stack rotate it up while a moment is
    /// still new. Faces ignore it.
    var relevance: TimelineEntryRelevance? {
        let relevance = WatchGlance.smartStackRelevance(summary, now: date)
        return TimelineEntryRelevance(score: relevance.score, duration: relevance.duration)
    }

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
        if family == .accessoryRectangular {
            // Drawn only in the Smart Stack — a face removes it — so the widget
            // reads as Pear'd's among the others rather than as default material.
            content.containerBackground(PearColor.accent.opacity(0.3).gradient, for: .widget)
        } else {
            content.containerBackground(.clear, for: .widget)
        }
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
struct PeardComplications: WidgetBundle {
    var body: some Widget {
        MomentComplication()
        WaterComplication()
    }
}

struct MomentComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeardComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Pear'd")
        .description("The latest moment and today's count, on a face or in the Smart Stack.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

// MARK: Water complication (#364)

/// A glanceable water complication: today's connection water as a ring toward
/// the goal, so the shared progress is on the wrist without opening the app.
///
/// The issue offered "water progress or the streak"; progress is the one the
/// widget feed already carries (the streak needs the recap route), and a ring is
/// the most glanceable thing a face has room for. It reads the same
/// `WaterProgress` the app does, so the ring means the same everywhere.
struct WaterComplicationEntry: TimelineEntry {
    let date: Date
    /// Nil when the feed carries no water (an older server, or water not tracked
    /// in this connection): the complication then says so rather than drawing an
    /// empty ring that reads as "zero of a goal".
    let water: WidgetFeed.Water?
    let state: FeedState

    static let placeholder = WaterComplicationEntry(
        date: Date(), water: WidgetFeed.Water(todayML: 1200, goalML: 2000), state: .ok)
    static let signedOut = WaterComplicationEntry(date: Date(), water: nil, state: .unpaired)
}

struct WaterComplicationProvider: TimelineProvider {
    static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> WaterComplicationEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WaterComplicationEntry) -> Void) {
        Task { completion(await Self.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterComplicationEntry>) -> Void) {
        Task {
            let entry = await Self.load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshInterval))))
        }
    }

    private static func load() async -> WaterComplicationEntry {
        let store = SharedStore.shared
        guard let credentials = WatchCredentials(store: store) else { return .signedOut }
        guard let feed = try? await APIClient(baseURL: credentials.baseURL).widgetFeed(
            token: credentials.token,
            pairID: store.selectedConnectionID
        ) else { return .placeholder }
        return WaterComplicationEntry(date: Date(), water: feed.water, state: feed.state)
    }
}

struct WaterComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WaterComplicationEntry

    var body: some View {
        content.containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Text(inlineText)
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            Text("💧")
                .font(.title3)
                .widgetLabel(cornerLabel)
        default:
            rectangular
        }
    }

    private var circular: some View {
        Gauge(value: entry.water?.progress.fraction ?? 0) {
            Text("💧").font(.system(size: 14))
        } currentValueLabel: {
            Text(percentText)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel("Water")
        .accessibilityValue(accessibilityValue)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("💧")
                Text("Water today").font(.headline).lineLimit(1)
            }
            if let water = entry.water {
                Gauge(value: water.progress.fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                Text(rectangularDetail(water)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(emptyText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Water today, \(accessibilityValue)")
    }

    // MARK: Copy

    private var percentText: String {
        guard let water = entry.water else { return "—" }
        return "\(Int((water.progress.fraction * 100).rounded()))%"
    }

    private var cornerLabel: String {
        guard let water = entry.water else { return emptyText }
        return water.progress.isRecommendedMet ? "goal met" : percentText
    }

    private var inlineText: String {
        guard let water = entry.water else { return "💧 \(emptyText)" }
        if water.progress.isRecommendedMet { return "💧 Water goal met" }
        return "💧 Water \(percentText)"
    }

    private func rectangularDetail(_ water: WidgetFeed.Water) -> String {
        if water.progress.isRecommendedMet { return "Goal met" }
        return "\(percentText) of today's goal"
    }

    private var emptyText: String {
        entry.state == .unpaired ? "Pear up" : "No water goal"
    }

    private var accessibilityValue: String {
        guard let water = entry.water else { return emptyText }
        return water.progress.isRecommendedMet ? "goal met" : "\(percentText) of goal"
    }
}

struct WaterComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeardWaterComplication", provider: WaterComplicationProvider()) { entry in
            WaterComplicationView(entry: entry)
        }
        .configurationDisplayName("Pear'd Water")
        .description("Today's water toward your goal, on a face or in the Smart Stack.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
