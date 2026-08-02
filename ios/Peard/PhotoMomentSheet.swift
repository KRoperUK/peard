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
///
/// The caption is the same `note` field a moment carries, and the edit sheet
/// has always called it a caption on a photo — so this is the missing half of
/// something the app could already display and edit, just not set at the point
/// where somebody actually has the words: right after taking the picture.
struct PhotoMomentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let moments: [Moment]
    /// The square as it was framed, the moment, and the caption. A nil moment
    /// means "share it as a photo", which is what Skip sends — the caption and
    /// the framing come either way, because Skip declines the *question*.
    let onSend: (UIImage, Moment?, String) -> Void

    @State private var chosen: Moment?
    @State private var caption = ""
    @State private var edit = PhotoEdit.identity
    @FocusState private var captionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SquarePhotoEditor(image: image, edit: $edit)
                    framingControls
                    captionField
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
            // Typing a caption fills the screen with keyboard, and the moment
            // grid sits below it — a flick should get back to the grid without
            // having to find a Done key first.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("What is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        send(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send(chosen)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Normalised here rather than at the caller, so a caption of nothing but
    /// spaces is the same as no caption at all.
    private func send(_ moment: Moment?) {
        let text = PostNote.normalised(caption)
        let square = PhotoSquare.render(image, edit: edit)
        dismiss()
        onSend(square, moment, text)
    }

    /// Fill or fit, and a turn.
    ///
    /// Two controls, not a toolbar: the framing that matters is the one nobody
    /// has to think about, and everything else here — the crop, the zoom — is
    /// done by dragging the picture itself.
    private var framingControls: some View {
        HStack(spacing: 12) {
            Picker("Framing", selection: $edit.fit) {
                Text("Fill").tag(PhotoFit.fill)
                Text("Fit").tag(PhotoFit.fit)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("How the photo fills the square")
            .accessibilityHint("Fill crops the edges. Fit keeps the whole photo and pads the sides.")

            Button {
                edit.rotate()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(PearColor.textPrimary)
                    .frame(width: 44, height: 32)
                    .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rotate")
            .accessibilityHint("Turns the photo a quarter turn clockwise")
        }
        // The whole point of Fit is not losing an edge, so a zoom left over
        // from Fill would quietly undo it.
        .onChange(of: edit.fit) { _, newValue in
            if newValue == .fit {
                edit.zoom = 1
                edit.offset = .zero
            }
        }
    }

    /// Optional, and unlabelled above the grid because the placeholder says
    /// what it is. It grows to five lines rather than scrolling a single one,
    /// since a caption people cannot re-read while writing gets abandoned.
    private var captionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $caption, prompt: Text("Add a caption (optional)…"), axis: .vertical)
                .focused($captionFocused)
                .lineLimit(1...5)
                .foregroundStyle(PearColor.textPrimary)
                .padding(12)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: caption) { _, newValue in
                    // Being told after the fact that it was too long is a
                    // worse way to find out.
                    caption = PostNote.capped(newValue)
                }
                .accessibilityLabel("Caption")

            if caption.count > 200 {
                Text("\(PostNote.limit - caption.count) characters left")
                    .font(.caption)
                    .foregroundStyle(PearColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var explanation: some View {
        if let chosen {
            Text("Sends as \(chosen.emoji) \(chosen.label), with the photo attached. It counts towards your tallies.")
        } else if !PostNote.isEmpty(caption) {
            // Skip sits where a cancel would, so with words on screen it has to
            // be said plainly that skipping keeps them.
            Text("Send it on its own, or pick what it's of. Either way the caption goes with it — Skip only skips the question.")
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
