import PeardCore
import SwiftUI

/// The moments, as a grid that uses whatever width there is.
///
/// Was a single horizontally-scrolling row of fixed 88-point tiles. Four of those
/// already overflowed a 402-point screen, so on any phone the fifth moment onward
/// was off-screen with only a sliver to hint at it — and the connection's own
/// invented moments are exactly the ones that end up past the fold. Wrapping into
/// rows instead means everything a connection logs is visible at once, more columns
/// appear on a wider screen or in landscape, and fewer appear at large Dynamic
/// Type rather than the labels truncating.
///
/// `.adaptive` rather than a fixed column count: the number of columns is a
/// function of the width, and hard-coding four is wrong on an iPad, wrong in
/// landscape, and wrong at accessibility text sizes.
struct MomentGrid: View {
    let moments: [Moment]
    /// The moment currently counting down, drawn as selected.
    let pendingKind: EventKind?
    let isBusy: Bool
    let onTap: (Moment) -> Void
    /// Nil where inventing a moment does not belong — the photo sheet asks what
    /// a picture is *of*, and publishing a new moment mid-send is a different
    /// errand.
    let onMore: (() -> Void)?

    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 80

    private var columns: [GridItem] {
        // The maximum matters as much as the minimum: without it, three moments on
        // an iPad become three enormous tiles rather than three normal ones.
        [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.5), spacing: 10)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(moments) { moment in
                tile(for: moment)
            }
            if onMore != nil {
                moreTile
            }
        }
        .opacity(isBusy ? 0.6 : 1)
    }

    private func tile(for moment: Moment) -> some View {
        let isPending = pendingKind == moment.kind
        return Button {
            onTap(moment)
        } label: {
            VStack(spacing: 4) {
                Text(moment.emoji)
                    .font(.largeTitle)
                Text(moment.label)
                    .font(.caption.bold())
                    .foregroundStyle(PearColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isPending ? PearColor.accent.opacity(0.18) : PearColor.surface,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                if isPending {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(PearColor.accent, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // Requirement 12.10.
        .disabled(isBusy)
        .accessibilityLabel("Log \(moment.label)")
        .accessibilityHint("Sends in \(Int(QuickSend.delay)) seconds unless you add a note")
    }

    /// Invent a moment. Last in the grid rather than pinned beside it: the grid
    /// wraps, so it can no longer be pushed off the right-hand edge, which is what
    /// the pinned version existed to prevent.
    @ViewBuilder
    private var moreTile: some View {
        Button { onMore?() } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.title.bold())
                    .foregroundStyle(PearColor.accent)
                Text("More")
                    .font(.caption.bold())
                    .foregroundStyle(PearColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(PearColor.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(PearColor.divider, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("More moments")
        .accessibilityHint("Pick a recommended moment, or invent one")
    }
}
