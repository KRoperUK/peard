import PeardCore
import SwiftUI

/// The last week, as a sentence rather than a number.
///
/// The app could say how many moments there had ever been and how many today,
/// and nothing in between. Neither is a story, and neither gives anybody a
/// reason to open the app when nobody has just sent them something. "Fourteen
/// this week, nine of them yours, five days running" is.
struct RecapSection: View {
    let recap: MomentRecap
    let mineLabel: String
    let othersLabel: String

    var body: some View {
        Section {
            if recap.isEmpty {
                Text("Nothing logged in the last week. It starts again whenever you do.")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            } else {
                headline
                if recap.streak.current > 0 || recap.streak.best > 1 {
                    streakRow
                }
                if let busiest = recap.busiest, busiest.count > 1 {
                    busiestRow(busiest)
                }
                if !recap.kinds.isEmpty {
                    kindsRow
                }
            }
        } header: {
            Text("Last 7 days")
        }
    }

    // MARK: Rows

    /// The total and the split. Both sides are named rather than "you and
    /// them", because in a group "them" is several people.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(recap.total)")
                .font(.title2.bold())
                .foregroundStyle(PearColor.accent)
                .monospacedDigit()
            Text(recap.total == 1 ? "moment" : "moments")
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
            Spacer()
            Text("\(mineLabel) \(recap.mine) · \(othersLabel) \(recap.others)")
                .font(.footnote)
                .foregroundStyle(PearColor.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(recap.total) moments in the last 7 days. \(mineLabel) \(recap.mine), \(othersLabel) \(recap.others)"
        )
    }

    /// A streak counts days anybody logged something, not days everybody did —
    /// see the server's recap package. The label says "you have" rather than
    /// naming anybody for that reason.
    private var streakRow: some View {
        HStack {
            Label {
                Text(streakText)
            } icon: {
                Text("🔥")
            }
            .font(.subheadline)
            .foregroundStyle(PearColor.textPrimary)
            Spacer()
            if recap.streak.best > recap.streak.current {
                Text("best \(recap.streak.best)")
                    .font(.caption)
                    .foregroundStyle(PearColor.textTertiary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var streakText: String {
        let current = recap.streak.current
        if current == 0 {
            return "Streak broken — best was \(recap.streak.best) days"
        }
        return current == 1 ? "1 day running" : "\(current) days running"
    }

    private func busiestRow(_ busiest: MomentRecap.BusiestDay) -> some View {
        HStack {
            Text("Busiest day")
                .font(.subheadline)
                .foregroundStyle(PearColor.textPrimary)
            Spacer()
            Text("\(busiestName(busiest.date)) · \(busiest.count)")
                .font(.footnote)
                .foregroundStyle(PearColor.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Busiest day, \(busiestName(busiest.date)), \(busiest.count) moments")
    }

    /// The server sends `yyyy-MM-dd` in the caller's own clock. Rendered as a
    /// weekday, which is how people remember a week — "Saturday", not "the
    /// 29th".
    private func busiestName(_ date: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let parsed = parser.date(from: date) else { return date }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: parsed)
    }

    /// Most-logged first, as the server ranked them. Capped so a connection
    /// with an inventive catalogue cannot turn a summary into a list.
    private var kindsRow: some View {
        HStack(spacing: 10) {
            ForEach(recap.kinds.prefix(4)) { kind in
                HStack(spacing: 3) {
                    Text(kind.emoji)
                    Text("\(kind.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PearColor.textPrimary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(kind.count) \(kind.label)")
            }
            Spacer()
        }
    }
}

/// The streak on its own, for the home screen.
///
/// Small and quiet: it belongs next to the moment buttons as encouragement, not
/// as a scoreboard. Absent entirely below two days, because "1 day running" is
/// not yet a streak and saying so makes it sound like one that is about to be
/// lost.
struct StreakBadge: View {
    let streak: MomentRecap.Streak

    var body: some View {
        if streak.current >= 2 {
            HStack(spacing: 4) {
                Text("🔥").font(.caption2)
                Text("\(streak.current) days running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PearColor.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(PearColor.surface, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(streak.current) days running")
        }
    }
}
