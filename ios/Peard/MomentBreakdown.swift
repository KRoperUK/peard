import PeardCore
import SwiftUI

/// Which moments a connection actually logs, rather than how many of them there
/// have been.
///
/// The tally rows answer "how many" — "You: T 7 W 15 M 15 All 15" — and stop
/// there. That is the least interesting half of the question in a connection that
/// has invented its own moments: fifteen is fifteen whether it was all beer or a
/// fortnight of dog walks. The server has counted per kind since the tallies
/// endpoint landed and sends the numbers on every refresh; nothing rendered them.
///
/// Composed rather than written inline: `MomentBreakdownRow` draws one moment,
/// `MomentBreakdownSection` embeds the set of them in a `Form` — the tallies tab and
/// nothing else, now that the tab bar means the breakdown has a screen of its own
/// rather than a one-line summary and a sheet.
struct MomentBreakdownRow: View {
    let kind: ConnectionTallies.Kind
    let window: TallyWindow
    /// The biggest count in this window, whatever kind. The bar's denominator, so
    /// the busiest moment fills its row and the rest scale against it.
    ///
    /// This was the window total until #301, which made every bar short: a row
    /// worth half of everything the connection logs read as "half filled" however
    /// lopsided its own two-way split was. Still each side's share of the row —
    /// only the length the row is drawn at changed.
    let busiest: Int
    let mineLabel: String
    let othersLabel: String

    private var mine: Int { kind.count(in: window, mine: true) }
    private var others: Int { kind.count(in: window, mine: false) }
    private var total: Int { mine + others }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(kind.emoji)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(kind.label)
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(total)")
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .monospacedDigit()
                }

                shareBar

                // The split is the point in a group: it is the difference between
                // "we drink a lot of coffee" and "one of us does".
                Text(splitText)
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Two-tone, so who logged them is visible without reading the numbers.
    ///
    /// `GeometryReader` because the widths are fractions of whatever the row turns
    /// out to be, and a proportional split of available space is the one thing
    /// stack layout will not do.
    private var shareBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let bar = BreakdownBarFractions(mine: mine, others: others, busiest: busiest)
            HStack(spacing: mine > 0 && others > 0 ? 1 : 0) {
                Capsule()
                    .fill(PearColor.accent)
                    .frame(width: bar.mine * width)
                Capsule()
                    .fill(PearColor.accent.opacity(0.35))
                    .frame(width: bar.others * width)
                Spacer(minLength: 0)
            }
            .frame(height: 5)
        }
        .frame(height: 5)
        .background(PearColor.divider.opacity(0.4), in: Capsule())
        .accessibilityHidden(true)
    }

    /// Names only the sides that logged something, so a moment only one person
    /// uses does not read "You 3 · Ari 0".
    private var splitText: String {
        switch (mine, others) {
        case (0, 0): return "none \(window.phrase)"
        case (let m, 0): return "\(mineLabel) \(m)"
        case (0, let o): return "\(othersLabel) \(o)"
        case (let m, let o): return "\(mineLabel) \(m) · \(othersLabel) \(o)"
        }
    }

    private var accessibilityText: String {
        let noun = total == 1 ? "moment" : "moments"
        return "\(kind.label): \(total) \(noun) \(window.phrase). \(splitText)."
    }
}

/// One row's two-tone bar, as fractions of the busiest row in the window.
///
/// Split out of the view so the proportions can be asserted without rendering
/// anything, which is what #301 was really about: a screenshot said "half filled"
/// and no test could disagree.
struct BreakdownBarFractions: Equatable {
    let mine: CGFloat
    let others: CGFloat

    init(mine: Int, others: Int, busiest: Int) {
        guard busiest > 0 else {
            self.mine = 0
            self.others = 0
            return
        }
        self.mine = CGFloat(max(mine, 0)) / CGFloat(busiest)
        self.others = CGFloat(max(others, 0)) / CGFloat(busiest)
    }
}

/// The window picker, shared so the two presentations cannot drift.
struct MomentBreakdownPicker: View {
    @Binding var window: TallyWindow

    var body: some View {
        Picker("Period", selection: $window) {
            ForEach(TallyWindow.allCases) { window in
                Text(window.shortLabel).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Tally period")
        .onChange(of: window) { Haptics.play(.changedPeriod) }
    }
}

/// The wording both presentations share. Kept in one place so the section and the
/// sheet cannot end up describing the same numbers differently.
enum MomentBreakdownCopy {
    static let unavailable = "This server counts moments the old way, so it can't break them down by kind."

    static func empty(_ window: TallyWindow, callToAction: String) -> String {
        switch window {
        case .day: return "Nothing logged today yet."
        case .week: return "Nothing logged this week yet."
        case .month: return "Nothing logged this month yet."
        case .all: return "No moments logged yet. \(callToAction)"
        }
    }

    static func summary(total: Int, kinds: Int, window: TallyWindow) -> String {
        let noun = total == 1 ? "moment" : "moments"
        let kindNoun = kinds == 1 ? "kind" : "kinds"
        return "\(total) \(noun) across \(kinds) \(kindNoun), \(window.phrase)."
    }
}

extension MomentBreakdownCopy {
    /// Who drank what today, naming only the sides that logged something, the
    /// way a row's split does.
    static func waterSplit(mine: Int, others: Int, mineLabel: String, othersLabel: String) -> String {
        switch (mine, others) {
        case (0, 0): return ""
        case (let m, 0): return "\(mineLabel) \(WaterAmount.label(m))"
        case (0, let o): return "\(othersLabel) \(WaterAmount.label(o))"
        case (let m, let o): return "\(mineLabel) \(WaterAmount.label(m)) · \(othersLabel) \(WaterAmount.label(o))"
        }
    }
}

/// Today's water in millilitres, for the whole connection (#320).
///
/// Always today, whichever window the breakdown below is showing: the total is
/// a daily one. Absent until somebody has logged water with an amount, rather
/// than a row reading "0 ml" in every connection that never drinks any. There is
/// no target to measure it against yet.
struct WaterTodaySection: View {
    let tallies: ConnectionTallies
    let mineLabel: String
    let othersLabel: String

    private var water: ConnectionTallies.Kind? { tallies.kinds.first { $0.kind == .water } }
    private var total: Int { tallies.waterToday }

    var body: some View {
        if total > 0, let water {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Text(water.emoji)
                        .font(.title3)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WaterAmount.todayLabel(total))
                            .font(.headline)
                            .foregroundStyle(PearColor.textPrimary)
                            .monospacedDigit()
                        Text(MomentBreakdownCopy.waterSplit(
                            mine: water.mine.dayAmount,
                            others: water.others.dayAmount,
                            mineLabel: mineLabel,
                            othersLabel: othersLabel
                        ))
                        .font(.caption2)
                        .foregroundStyle(PearColor.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Water")
            }
        }
    }
}

/// The breakdown as a `Form` section, for the connection's settings screen.
struct MomentBreakdownSection: View {
    let tallies: ConnectionTallies
    let mineLabel: String
    let othersLabel: String
    /// False when the counts came from the on-device fallback, which cannot
    /// produce a per-moment split. Saying so beats an empty list that looks broken.
    let isServerSide: Bool
    @Binding var window: TallyWindow

    private var kinds: [ConnectionTallies.Kind] { tallies.rankedKinds(in: window) }
    private var total: Int { tallies.total(in: window) }
    /// The busiest row draws at full width and the rest scale against it, so the
    /// bars are comparable with one another and the top one actually fills.
    private var busiest: Int { kinds.map { $0.total(in: window) }.max() ?? 0 }

    var body: some View {
        Section {
            MomentBreakdownPicker(window: $window)

            if !isServerSide {
                Text(MomentBreakdownCopy.unavailable)
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            } else if kinds.isEmpty {
                Text(MomentBreakdownCopy.empty(window, callToAction: "Tap one on the home screen to start."))
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            } else {
                ForEach(kinds) { kind in
                    MomentBreakdownRow(
                        kind: kind,
                        window: window,
                        busiest: busiest,
                        mineLabel: mineLabel,
                        othersLabel: othersLabel
                    )
                }
            }
        } header: {
            Text("Moments")
        } footer: {
            if isServerSide && !kinds.isEmpty {
                Text(MomentBreakdownCopy.summary(total: total, kinds: kinds.count, window: window))
            }
        }
    }
}
