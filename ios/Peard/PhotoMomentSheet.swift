import PeardCore
import SwiftUI

/// What a photo is *of*, asked once the picture is taken.
///
/// A photo used to be its own kind of post, which meant "coffee, and here it
/// is" was two posts: a coffee the tallies counted and a picture they ignored.
/// Attaching a moment makes it one post that is both — it counts, it appears in
/// the recap, it keeps the streak — and the picture is the note.
///
/// Skipping is a first-class answer and is on the left where a cancel would be,
/// because most photos are not of anything countable. The sheet exists to make
/// attaching *possible*, not expected: a photo shared with nothing attached is
/// exactly what it was before this, and the flow costs one extra tap.
struct PhotoMomentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let moments: [Moment]
    /// Nil means "share it as a photo", which is what Skip sends.
    let onSend: (Moment?) -> Void

    @State private var chosen: Moment?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    preview
                    MomentGrid(
                        moments: moments,
                        // The grid highlights what is being sent, so its
                        // "pending" slot is reused for the current choice —
                        // tapping the same one again clears it, because
                        // changing your mind should not need the Skip button.
                        pendingKind: chosen?.kind,
                        isBusy: false,
                        onTap: { moment in
                            chosen = (chosen?.kind == moment.kind) ? nil : moment
                        },
                        onMore: nil
                    )
                    explanation
                }
                .padding(20)
            }
            .background(PearColor.background)
            .navigationTitle("What is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        dismiss()
                        onSend(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let moment = chosen
                        dismiss()
                        onSend(moment)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("The photo you just took")
    }

    @ViewBuilder
    private var explanation: some View {
        if let chosen {
            Text("Sends as \(chosen.emoji) \(chosen.label), with the photo attached. It counts towards your tallies.")
        } else {
            Text("Send it on its own, or pick what it's of — a moment with a photo still counts towards your tallies.")
        }
    }
}

/// A just-taken photo, wrapped so it can drive `sheet(item:)`.
///
/// `UIImage` is not `Identifiable` and two photos are not meaningfully equal,
/// so the identity is the capture rather than the pixels — which is right:
/// taking the same picture twice is two things to send.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}
