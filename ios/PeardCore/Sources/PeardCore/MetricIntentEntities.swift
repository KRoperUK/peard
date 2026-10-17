import AppIntents
import Foundation

/// A tracked metric, as the complication's picker sees it (#392).
///
/// The entity is what the system stores in a face's configuration, and it holds
/// only the slug — no amount, no goal. The provider resolves that slug against
/// the feed at render time, so a metric the connection stops tracking simply
/// disappears from the next feed and the complication falls back, rather than
/// drawing a ring from a value frozen into the configuration the day it was set.
public struct MetricEntity: AppEntity, Identifiable, Hashable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    public static var defaultQuery = MetricQuery()

    /// The metric's slug, which is what `WidgetFeed.MetricSummary.slug` carries
    /// and what a stored configuration is matched back against.
    public let id: String
    public let title: String
    public let emoji: String

    public init(id: String, title: String, emoji: String) {
        self.id = id
        self.title = title
        self.emoji = emoji
    }

    public init(_ summary: WidgetFeed.MetricSummary) {
        self.init(id: summary.slug, title: summary.label, emoji: summary.emoji)
    }

    /// The emoji leads: a metric is picked by looking, and the label alone
    /// ("exercise") is ambiguous where the ring on the face is not.
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji) \(title)")
    }
}

/// Supplies the picker's metrics from the connection's feed, using the widget
/// token — the same credential and the same request the complications read, so
/// the list offered is exactly what the feed will have to draw.
public struct MetricQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [MetricEntity] {
        let all = try await suggestedEntities()
        // Preserve the asked-for order, and silently drop a metric that is no
        // longer tracked: a face configured for one the connection has stopped
        // counting must fall back, not fail to render.
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    public func suggestedEntities() async throws -> [MetricEntity] {
        try await MomentIntentSource.trackedMetrics().map { MetricEntity($0) }
    }
}
