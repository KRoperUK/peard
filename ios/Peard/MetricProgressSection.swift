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

/// One metric's day: how much so far, a bar toward the goal, and — in a
/// connection of more than one — a two-tone split showing who logged what, drawn
/// the same way `MomentBreakdownRow` splits a moment so the two presentations do
/// not drift (#386).
struct MetricProgressRow: View {
    let summary: WidgetFeed.MetricSummary

    private var definition: MetricDefinition { summary.definition }

    /// This user's own amount today, the accent side of the split bar.
    private var mine: Int { summary.members.first { $0.isYou }?.amount ?? 0 }
    /// Everybody else's amount today, summed — the muted side.
    private var others: Int { summary.members.filter { !$0.isYou }.reduce(0) { $0 + $1.amount } }
    /// Drawn only when there is more than one person to compare; a solo
    /// connection's single row would just restate the total above.
    private var showsSplit: Bool { summary.members.count > 1 }

    /// The other side's label: the sole partner's name in a pair, or a generic
    /// word in a group, mirroring how a moment row names the non-caller side.
    private var othersLabel: String {
        let them = summary.members.filter { !$0.isYou }
        return them.count == 1 ? them[0].name : String(localized: "Others")
    }

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

                // Who logged what, the same two-tone bar and "You 9,000 · Ari
                // 7,000" line a moment row uses — the split is the point of a
                // metric in a connection that competes on it.
                if showsSplit {
                    shareBar
                    Text(splitText)
                        .font(.caption2)
                        .foregroundStyle(PearColor.textTertiary)
                }
            }
        }
        // The same vertical rhythm as the totals, water and moment rows (#465).
        .padding(.vertical, 2)
        // A one-shot burst and a success tick the moment this metric's goal is
        // met (#421). Reduce Motion draws no particles; the "Goal met" badge in
        // the detail line stays the durable signal either way.
        .overlay { CelebrationBurst(isActive: summary.progress.isGoalMet) }
        .sensoryFeedback(.success, trigger: summary.progress.isGoalMet)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Two-tone, mine against theirs, as a share of the full bar — the two
    /// segments split the width between them (a 100%-stacked bar), so the row
    /// shows who contributed more.
    ///
    /// A `GeometryReader`, not container-relative frames: in a `Form` row the
    /// "container" is the whole form, so the bars sized to the full width,
    /// stretched the row, and pushed the readout off the card (#466).
    private var shareBar: some View {
        let gap: CGFloat = (mine > 0 && others > 0) ? 1 : 0
        let total = mine + others
        let mineFraction = total > 0 ? CGFloat(mine) / CGFloat(total) : 0
        return GeometryReader { geo in
            HStack(spacing: gap) {
                Capsule()
                    .fill(PearColor.accent)
                    .frame(width: max(geo.size.width - gap, 0) * mineFraction)
                Capsule()
                    .fill(PearColor.accent.opacity(0.35))
                    .frame(width: max(geo.size.width - gap, 0) * (1 - mineFraction))
            }
        }
        .frame(height: 5)
        .background(PearColor.divider.opacity(0.4), in: Capsule())
        .accessibilityHidden(true)
    }

    /// "You 9,000 · Ari 7,000", in the metric's own unit — naming only the sides
    /// that logged something, exactly as a moment row's split does.
    private var splitText: String {
        Self.split(mine: mine, others: others, othersLabel: othersLabel, definition: definition)
    }

    /// Pulled out so the wording can be asserted without rendering.
    static func split(
        mine: Int,
        others: Int,
        othersLabel: String,
        definition: MetricDefinition,
        locale: Locale = .current
    ) -> String {
        let you = String(localized: "You")
        func amount(_ v: Int) -> String { definition.readout(v, locale: locale) }
        // A crown on the leading side when both logged and it is not a tie, so
        // "who's ahead" reads without relying on the bar's length or colour —
        // legible in grayscale and spoken by VoiceOver (#426).
        let crown = "👑"
        switch (mine, others) {
        case (0, 0): return String(localized: "none today")
        case (let m, 0): return String(localized: "\(you) \(amount(m))")
        case (0, let o): return String(localized: "\(othersLabel) \(amount(o))")
        case (let m, let o) where m > o:
            return String(localized: "\(you) \(amount(m)) \(crown) · \(othersLabel) \(amount(o))")
        case (let m, let o) where o > m:
            return String(localized: "\(you) \(amount(m)) · \(othersLabel) \(amount(o)) \(crown)")
        case (let m, let o):
            return String(localized: "\(you) \(amount(m)) · \(othersLabel) \(amount(o))")
        }
    }

    private var accessibilityText: String {
        let headline = String(
            localized: "\(summary.label): \(definition.readout(summary.today)) of \(definition.readout(summary.goal))"
        )
        return showsSplit ? "\(headline). \(splitText)." : headline
    }

    /// What is left, in the metric's own unit — or that the goal is met. Whole
    /// sentences rather than a pluralised noun, as the rest of the copy does.
    /// The goal reads bare ("your goal of 20,000"): the row above already says
    /// steps, so repeating the unit reads twice (#467).
    static func detail(
        _ progress: MetricProgress,
        definition: MetricDefinition,
        locale: Locale = .current
    ) -> String {
        if progress.isGoalMet {
            // The same key the water badge and the complications use, so the
            // met state reads one way everywhere.
            return String(localized: "Goal met")
        }
        return String(
            localized: "\(definition.readout(progress.remaining, locale: locale)) to go until your goal of \(progress.goal.formatted(.number.locale(locale)))"
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
        // A GeometryReader, not a container-relative frame: in a Form row the
        // "container" is the whole form, so the bar sized to the full width
        // and stretched the row (#466).
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PearColor.divider.opacity(0.4))
                Capsule().fill(fill)
                    .frame(width: progress.fraction * geo.size.width)
            }
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}
