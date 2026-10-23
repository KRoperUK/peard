import PeardCore
import SwiftUI

/// Today's tracked daily metrics, for the whole connection (#390), drawn from
/// `feed.metrics` (#389).
///
/// Water keeps its own section above: that one measures *this user's* day
/// against their own targets (#335), while these are the connection's summed
/// amount against the summed goal. Two different bases — showing water twice
/// with different numbers would be worse than leaving it out here.
///
/// Absent entirely when the connection tracks nothing else, and on a server that
/// predates generalised metrics (an empty `metrics`).
struct MetricProgressSection: View {
    let metrics: [WidgetFeed.MetricSummary]

    private var shown: [WidgetFeed.MetricSummary] {
        metrics.filter { $0.slug != EventKind.water.rawValue }
    }

    var body: some View {
        if !shown.isEmpty {
            Section {
                ForEach(shown) { summary in
                    MetricProgressRow(summary: summary)
                }
            } header: {
                Text("Other metrics")
            } footer: {
                Text("Today, against the goal everybody in this connection has set.")
            }
        }
    }
}

/// One metric's day: how much so far, a bar toward the goal, and what is left.
struct MetricProgressRow: View {
    let summary: WidgetFeed.MetricSummary

    private var definition: MetricDefinition { summary.definition }

    var body: some View {
        let progress = summary.progress

        HStack(alignment: .top, spacing: 12) {
            Text(summary.emoji)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.label)
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(definition.readout(summary.today))
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .monospacedDigit()
                }

                MetricProgressBar(progress: progress)

                Text(Self.detail(progress, definition: definition))
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)

                // Per-person breakdown so partners can compete (#386). Only
                // shown once there is more than one member to compare; a solo
                // connection's single row would just restate the total above.
                if summary.members.count > 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(summary.members) { member in
                            MetricMemberRow(member: member, definition: definition)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(summary.label): \(definition.readout(summary.today)) of \(definition.readout(summary.goal))"
        )
    }

    /// What is left, in the metric's own unit — or that the goal is met. Whole
    /// sentences rather than a pluralised noun, as the rest of the copy does.
    static func detail(
        _ progress: MetricProgress,
        definition: MetricDefinition,
        locale: Locale = .current
    ) -> String {
        if progress.isGoalMet {
            return String(localized: "Goal met · \(definition.readout(progress.goal, locale: locale))")
        }
        return String(
            localized: "\(definition.readout(progress.remaining, locale: locale)) to the \(definition.readout(progress.goal, locale: locale)) goal"
        )
    }
}

/// One person's line in a metric's breakdown: their name (with "you" called
/// out), their amount so far, and a short gloss of how they stand against their
/// own goal — so the two members of a connection can see who is ahead (#386).
struct MetricMemberRow: View {
    let member: WidgetFeed.MetricSummary.Member
    let definition: MetricDefinition

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(member.isYou ? String(localized: "You") : member.name)
                .font(.caption2.weight(member.isYou ? .semibold : .regular))
                .foregroundStyle(member.isYou ? PearColor.textPrimary : PearColor.textSecondary)
                .lineLimit(1)
            if member.progress.isGoalMet {
                Text("· goal met")
                    .font(.caption2)
                    .foregroundStyle(PearColor.accent)
            }
            Spacer(minLength: 4)
            Text(definition.readout(member.amount))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PearColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.isYou ? String(localized: "You") : member.name): \(definition.readout(member.amount)) of \(definition.readout(member.goal))"
        )
    }
}

/// A bar toward the goal, with the fill getting stronger as it is approached.
///
/// The same three states as the water bar, told apart by more than colour: the
/// fill darkens, and the line beneath says where the day stands. There is no
/// minimum tick because a generalised metric's feed carries only the goal
/// (#389).
struct MetricProgressBar: View {
    let progress: MetricProgress

    private var fill: Color {
        switch progress.stage {
        case .none, .underMinimum: return PearColor.textTertiary
        case .minimumMet: return PearColor.accent.opacity(0.55)
        case .goalMet: return PearColor.accent
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(PearColor.divider.opacity(0.4))
                Capsule().fill(fill).frame(width: progress.fraction * width)
            }
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}
