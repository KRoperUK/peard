import PeardCore
import SwiftUI

/// Marks a moment that was logged after it happened.
///
/// Rewinding puts a moment where it belongs in the timeline and the tallies,
/// which is the point — but a shared record should still say that it was filled
/// in later rather than in the moment, so nobody reads "8:40pm" as "they told us
/// at 8:40pm".
struct RewoundChip: View {
    /// When the moment actually reached the server, for VoiceOver.
    let loggedAt: Date

    var body: some View {
        // Laid out by hand rather than as a `Label`: inside a List row the
        // system label style stacks the icon over a title it then squeezes to
        // nothing, which drew a tall empty pill.
        HStack(spacing: 3) {
            Image(systemName: "backward.fill")
                .imageScale(.small)
            Text("Rewound")
                .lineLimit(1)
        }
        .font(.caption2.bold())
        .foregroundStyle(PearColor.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(PearColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(PearColor.divider))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(loggedAt: loggedAt))
    }

    static func accessibilityLabel(loggedAt: Date) -> String {
        "Rewound, logged later at \(loggedAt.formatted(date: .omitted, time: .shortened))"
    }
}
