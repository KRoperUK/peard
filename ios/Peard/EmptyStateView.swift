import PeardCore
import SwiftUI

/// A warm, consistent empty state — an accent-treated symbol, one line of copy,
/// and an optional primary action — for the screens a new or quiet connection
/// sees first (#425). One component so home, history and the tallies read the
/// same rather than each inventing its own terse string.
///
/// Themed entirely through the palette variables, so it is correct in light and
/// dark; it sets no fixed colour.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(PearColor.accent)
                .padding(18)
                .background(PearColor.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(PearColor.textPrimary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.bold())
                    .foregroundStyle(PearColor.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(PearColor.accent, in: Capsule())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        // Contain, never combine: combining would merge the action button into
        // the text, and VoiceOver could no longer activate it (#452).
        .accessibilityElement(children: .contain)
    }
}
