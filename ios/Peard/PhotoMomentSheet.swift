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
    /// Whose photo this one answers ("Ada's"), when it is a photo sent back
    /// from the viewer. Then there is no question to ask — an answer is never a moment
    /// — so the grid goes and Skip becomes Cancel.
    var replyingTo: String?
    /// The square as it was framed, the moment, and the caption. A nil moment
    /// means "share it as a photo", which is what Skip sends — the caption and
    /// the framing come either way, because Skip declines the *question*.
    let onSend: (UIImage, Moment?, String) -> Void

    /// A moment carried in from the home send flow: the user had tapped a
    /// moment type (its countdown running) and then chose to attach a photo, so
    /// the sheet opens with that moment already picked, matching the
    /// photo-first order (issue #312). Nil for a plain "Share a photo".
    var preselected: Moment?

    @State private var chosen: Moment?
    @State private var caption = ""
    @State private var edit = PhotoEdit.identity
    /// The zoom and pan somebody had in Fill, kept while they look at Fit so
    /// coming back to Fill puts the picture where they left it (issue #13).
    @State private var fillFraming: (zoom: CGFloat, offset: CGSize)?
    /// Set while the square is being drawn, off the main thread: it can take a
    /// moment for a full-size photo, and the sheet should say so rather than
    /// freeze (issue #1).
    @State private var isRendering = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SquarePhotoEditor(image: image, edit: $edit)
                    framingControls
                    captionField
                    if replyingTo == nil {
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
                            onMore: nil,
                            purpose: .pick
                        )
                    }
                    explanation
                }
                .padding(20)
            }
            .background(PearColor.background)
            // The moment carried in from the home send flow becomes the
            // pre-selected choice (issue #312). Done here rather than in an
            // initialiser because `chosen` is `@State`, which cannot be seeded
            // from a stored property; the sheet is created fresh per photo, so
            // this runs once.
            .onAppear {
                if chosen == nil, let preselected { chosen = preselected }
            }
            // Typing a caption fills the screen with keyboard, and the moment
            // grid sits below it — a flick should get back to the grid without
            // having to find a Done key first.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(replyingTo == nil ? "What is it?" : "Reply with a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if replyingTo == nil {
                        Button("Skip") {
                            send(nil)
                        }
                        .disabled(isRendering)
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled(isRendering)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRendering {
                        ProgressView()
                            .accessibilityLabel("Preparing the photo")
                    } else {
                        Button("Send") {
                            send(chosen)
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    /// Normalised here rather than at the caller, so a caption of nothing but
    /// spaces is the same as no caption at all.
    private func send(_ moment: Moment?) {
        guard !isRendering else { return }
        isRendering = true
        let text = PostNote.normalised(caption)
        let image = image
        let edit = edit
        Task {
            let square = await Task.detached(priority: .userInitiated) {
                PhotoSquare.render(image, edit: edit)
            }.value
            dismiss()
            onSend(square, moment, text)
        }
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

            // Only once there is something to undo: an always-there reset is a
            // button that does nothing most of the time.
            if !edit.isIdentity {
                Button {
                    fillFraming = nil
                    edit = .identity
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body.weight(.medium))
                        .foregroundStyle(PearColor.textPrimary)
                        .frame(width: 44, height: 32)
                        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset")
                .accessibilityHint("Puts the photo back the way it was taken")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: edit.isIdentity)
        // The whole point of Fit is not losing an edge, so a zoom left over
        // from Fill would quietly undo it.
        .onChange(of: edit.fit) { oldValue, newValue in
            if newValue == .fit {
                if oldValue == .fill, edit.zoom != 1 || edit.offset != .zero {
                    fillFraming = (edit.zoom, edit.offset)
                }
                edit.zoom = 1
                edit.offset = .zero
            } else if let framing = fillFraming {
                // Back to Fill: where they had it, not the default crop.
                edit.zoom = framing.zoom
                edit.offset = framing.offset
                fillFraming = nil
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
        if let replyingTo {
            Text("Sends to everyone here as a reply to \(replyingTo) photo.")
        } else if let chosen {
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
