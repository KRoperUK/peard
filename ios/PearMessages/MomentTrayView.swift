import PeardCore
import SwiftUI

/// The compact tray: one tap per built-in moment, same three as the widget
/// and Siri offer, logged into whichever connection is liveliest — no
/// connection picker here, matching the same call made for Siri.
struct MomentTrayView: View {
    struct Moment: Identifiable {
        let eventKind: EventKind
        let emoji: String
        let label: String
        var id: String { eventKind.rawValue }
    }

    /// What the tray is doing, so a tap is visibly acknowledged.
    ///
    /// The widget solves this with `pendingWidgetLog`, and says why in its own
    /// doc comment: without an immediate acknowledgement the only sign of life
    /// is the tallies changing after a round trip, which on a slow connection
    /// reads as a button that does nothing. This tray had the same problem and
    /// none of the solution — it ran the log in a detached task and changed
    /// nothing on screen at all.
    enum Status: Equatable {
        case idle
        case logging(Moment.ID)
        case logged(String)
        case failed
    }

    /// Mirrors MomentCatalogue.builtin; kept local rather than shared so this
    /// target has no more surface area than it needs.
    static let moments: [Moment] = [
        Moment(eventKind: .beer, emoji: "🍺", label: "Beer"),
        Moment(eventKind: .loo, emoji: "💩", label: "Loo"),
        Moment(eventKind: .coffee, emoji: "☕", label: "Coffee"),
    ]

    let isSignedIn: Bool
    let status: Status
    let onTap: (Moment) -> Void

    var body: some View {
        Group {
            if isSignedIn {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        ForEach(Self.moments) { moment in
                            button(for: moment)
                        }
                    }
                    statusLine
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
        .animation(.easeOut(duration: 0.2), value: status)
    }

    private func button(for moment: Moment) -> some View {
        Button {
            onTap(moment)
        } label: {
            ZStack {
                if status == .logging(moment.id) {
                    ProgressView()
                } else {
                    Text(moment.emoji)
                        .font(.system(size: 34))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.plain)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 14))
        // Disabled only while a log is in flight: a second tap during the round
        // trip would log the moment twice, and the tray is small enough that the
        // first tap's spinner is easy to miss.
        .disabled(isBusy)
        .opacity(isBusy && status != .logging(moment.id) ? 0.4 : 1)
        .accessibilityLabel("Log \(moment.label)")
    }

    private var isBusy: Bool {
        if case .logging = status { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle, .logging:
            // Held open so the tray does not resize under the user's thumb when
            // a result arrives; Messages gives it very little height to start.
            Text(" ").font(.caption2)
        case .logged(let label):
            Text("\(label) logged")
                .font(.caption2)
                .foregroundStyle(PearColor.accent)
        case .failed:
            // Says what happened and what to do. The alternative — silence —
            // used to be paired with a message bubble claiming success.
            Text("Couldn't log that. Open Pear'd and try again.")
                .font(.caption2)
                .foregroundStyle(PearColor.error)
                .multilineTextAlignment(.center)
        }
    }
}
