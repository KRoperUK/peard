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
/// Composed rather than written twice: `MomentBreakdownSection` embeds in the
/// connection's settings `Form`, `MomentBreakdownSheet` presents the same rows
/// from the home screen's tallies. Both draw `MomentBreakdownRow`.
struct MomentBreakdownRow: View {
    let kind: ConnectionTallies.Kind
    let window: TallyWindow
    /// Everybody's moments in this window, whatever kind. The bar's denominator,
    /// so a row's width reads as its share of what the connection logs.
    let windowTotal: Int
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
            HStack(spacing: mine > 0 && others > 0 ? 1 : 0) {
                Capsule()
                    .fill(PearColor.accent)
                    .frame(width: fraction(of: mine) * width)
                Capsule()
                    .fill(PearColor.accent.opacity(0.35))
                    .frame(width: fraction(of: others) * width)
                Spacer(minLength: 0)
            }
            .frame(height: 5)
        }
        .frame(height: 5)
        .background(PearColor.divider.opacity(0.4), in: Capsule())
        .accessibilityHidden(true)
    }

    /// Guarded against a zero denominator: a window with no moments in it renders
    /// no rows at all, but the row must not divide by zero if it ever does.
    private func fraction(of count: Int) -> CGFloat {
        guard windowTotal > 0, count > 0 else { return 0 }
        return CGFloat(count) / CGFloat(windowTotal)
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
                        windowTotal: total,
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

/// The breakdown as its own screen, reached from the home screen's tally rows.
///
/// A sheet rather than an inline expansion: the home screen deliberately fits
/// without scrolling at default text size, and a connection with a dozen invented
/// moments would be a dozen rows pushing the camera button off the bottom.
struct MomentBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss

    let tallies: ConnectionTallies
    let connectionTitle: String
    let mineLabel: String
    let othersLabel: String
    let isServerSide: Bool

    @State private var window: TallyWindow = .all

    private var kinds: [ConnectionTallies.Kind] { tallies.rankedKinds(in: window) }
    private var total: Int { tallies.total(in: window) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MomentBreakdownPicker(window: $window)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                content
            }
            .background(PearColor.background)
            .navigationTitle("Moments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Moments")
                            .font(.headline)
                            .foregroundStyle(PearColor.textPrimary)
                        Text(connectionTitle)
                            .font(.caption2)
                            .foregroundStyle(PearColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isServerSide {
            message(MomentBreakdownCopy.unavailable)
        } else if kinds.isEmpty {
            message(MomentBreakdownCopy.empty(window, callToAction: "Tap one to start."))
        } else {
            List {
                ForEach(kinds) { kind in
                    MomentBreakdownRow(
                        kind: kind,
                        window: window,
                        windowTotal: total,
                        mineLabel: mineLabel,
                        othersLabel: othersLabel
                    )
                    .listRowBackground(PearColor.surface)
                }

                Text(MomentBreakdownCopy.summary(total: total, kinds: kinds.count, window: window))
                    .font(.footnote)
                    .foregroundStyle(PearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text("🍐").font(.system(size: 44)).accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
