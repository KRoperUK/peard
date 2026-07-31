import PeardCore
import SwiftUI

/// The compact tray: one tap per built-in moment, same three as the widget
/// and Siri offer, logged into whichever connection is liveliest — no
/// connection picker here, matching the same call made for Siir.
struct MomentTrayView: View {
    struct Moment: Identifiable {
        let eventKind: EventKind
        let emoji: String
        let label: String
        var id: String { eventKind.rawValue }
    }

    /// Mirrors MomentCatalogue.builtin; kept local rather than shared so this
    /// target has no more surface area than it needs.
    static let moments: [Moment] = [
        Moment(eventKind: .beer, emoji: "🍺", label: "Beer"),
        Moment(eventKind: .loo, emoji: "💩", label: "Loo"),
        Moment(eventKind: .coffee, emoji: "☕", label: "Coffee"),
    ]

    let isSignedIn: Bool
    let onTap: (Moment) -> Void

    var body: some View {
        Group {
            if isSignedIn {
                HStack(spacing: 12) {
                    ForEach(Self.moments) { moment in
                        Button {
                            onTap(moment)
                        } label: {
                            Text(moment.emoji)
                                .font(.system(size: 34))
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.plain)
                        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Log \(moment.label)")
                    }
                }
                .padding(16)
            } else {
                Text("🍐 Sign in to Pear'd first, then come back here.")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity)
        .background(PearColor.background)
    }
}
