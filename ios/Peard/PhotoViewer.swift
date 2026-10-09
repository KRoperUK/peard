import PeardCore
import Photos
import SwiftUI

/// A shared photo, at the size it was taken.
///
/// Until now a photo could be shared but never really looked at: the timeline
/// drew it 36 points across and the home screen 72, and tapping either did
/// nothing. For an app whose main button is "Share a photo", the picture was the
/// one thing you could not see.
///
/// Pinch or double-tap to zoom, drag to pan, swipe down to dismiss. The note and
/// who sent it stay on screen, because a photo in a shared timeline is usually
/// half of something somebody said.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let post: Post
    let serverURL: URL
    let authorLabel: String
    let timestamp: String

    @State private var zoom: CGFloat = 1
    /// Committed zoom, so a second pinch starts from where the last one ended
    /// rather than snapping back to 1.
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var loaded: Image?
    /// The same bytes as `loaded`, kept because the share sheet and the photo
    /// library need an image they can copy, not one that has been drawn.
    @State private var fullSize: UIImage?
    @State private var failed = false
    @State private var saveOutcome: String?
    /// Whether what is on screen is the photo as uploaded. Under low data it
    /// starts as the 1024 thumbnail, and becomes the original only on request.
    @State private var isOriginal = false
    @State private var isLoadingOriginal = false
    /// How many posts answer this photo. Nil until counted, and left nil on a
    /// server that has never heard of replies.
    @State private var replyCount: Int?
    @State private var composingComment = false
    @State private var showCamera = false
    @State private var replyPhoto: CapturedPhoto?

    /// Built at load time rather than up front, because the token has to be
    /// fetched: `posts.media` is protected, and the path alone is a 404.
    private func url(token: String, thumb: PhotoThumb?) -> URL? {
        guard let path = thumb.map({ post.mediaThumbnailPath($0) }) ?? post.mediaPath() else { return nil }
        return URL(string: serverURL.absoluteString + FileTokenStore.decorate(path, token: token))
    }

    private var isZoomedIn: Bool { zoom > 1.01 }

    var body: some View {
        ZStack {
            // Black rather than the app's cream: everything here is the photo,
            // and a warm background tints how the photo reads.
            Color.black.ignoresSafeArea()

            photo

            VStack {
                topBar
                Spacer()
                if !isZoomedIn {
                    caption
                }
            }
            // Hidden while zoomed in, because at that point the chrome is
            // covering the part somebody zoomed in to look at.
            .opacity(isZoomedIn ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isZoomedIn)
        }
        .statusBarHidden()
        .task { await countReplies() }
        .sheet(isPresented: $composingComment) {
            PhotoCommentSheet(whose: possessive) { text in
                Task { await sendReply(note: text, image: nil) }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            let picked: (UIImage?) -> Void = { image in
                showCamera = false
                guard let image else { return }
                replyPhoto = CapturedPhoto(image: image)
            }
            if CameraPicker.canUseCamera {
                CameraPicker(completion: picked).ignoresSafeArea()
            } else {
                LibraryPicker(completion: picked).ignoresSafeArea()
            }
        }
        .sheet(item: $replyPhoto) { photo in
            PhotoMomentSheet(image: photo.image, moments: [], replyingTo: possessive) { square, _, caption in
                Task { await sendReply(note: caption, image: square) }
            }
        }
    }

    // MARK: Replies

    /// Somebody else's photo, and one the server has. Answering your own would
    /// tell the others "Ada replied to their photo", which is a caption with
    /// extra steps — and editing the caption is already there. A photo still
    /// waiting to send has no id anybody else can point at yet.
    private var canReply: Bool {
        post.author != app.signedInUserID && !post.id.hasPrefix("pending:")
    }

    private var possessive: String { "\(authorLabel)'s" }

    private func countReplies() async {
        guard !post.id.hasPrefix("pending:") else { return }
        replyCount = try? await app.api.replyCount(to: post.id)
    }

    /// Reports the outcome where saving to Photos does, so there is one line
    /// of news on the viewer rather than two competing for it.
    private func sendReply(note: String, image: UIImage?) async {
        guard await app.reply(to: post, note: note, image: image) else {
            saveOutcome = String(localized: "Couldn't send that reply.")
            return
        }
        replyCount = (replyCount ?? 0) + 1
        saveOutcome = app.isOnline ? String(localized: "Reply sent.") : String(localized: "Reply saved — will send.")
    }

    // MARK: Photo

    @ViewBuilder
    private var photo: some View {
        if let loaded {
            loaded
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(magnification)
                .gesture(drag)
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityLabel("Photo from \(authorLabel)")
        } else if failed {
            VStack(spacing: 10) {
                Text("📷").font(.system(size: 44)).accessibilityHidden(true)
                Text("This photo couldn't be loaded.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        } else {
            ProgressView()
                .tint(.white)
                .task { await load(thumb: PhotoThumb.viewer(lowData: app.isLowDataActive)) }
        }
    }

    /// Loaded here rather than with `AsyncImage` because the same bytes are
    /// needed twice: once to draw, once to hand to the share sheet or the photo
    /// library. `AsyncImage` gives a `SwiftUI.Image` and no way back to the data.
    ///
    /// A non-2xx is treated as a failure rather than decoded: PocketBase answers
    /// a missing file with a JSON error body, and `UIImage(data:)` would simply
    /// return nil on it, which reads the same as a corrupt photo.
    ///
    /// `thumb` is nil for the original. A failure to fetch the original over a
    /// thumbnail already on screen leaves the thumbnail there: a worse photo
    /// beats no photo.
    private func load(thumb: PhotoThumb?) async {
        let replacing = loaded != nil
        guard let token = await app.fileTokens.current(), let url = url(token: token, thumb: thumb) else {
            if !replacing { failed = true }
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data) else {
                if !replacing { failed = true }
                return
            }
            fullSize = image
            loaded = Image(uiImage: image)
            isOriginal = thumb == nil
        } catch {
            if !replacing { failed = true }
        }
    }

    private func loadOriginal() async {
        isLoadingOriginal = true
        defer { isLoadingOriginal = false }
        await load(thumb: nil)
    }

    // MARK: Gestures

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Floored at 1 so the photo cannot be pinched smaller than the
                // screen and left floating in the middle of the black.
                zoom = max(1, committedZoom * value.magnification)
            }
            .onEnded { _ in
                committedZoom = zoom
                if !isZoomedIn { resetPan() }
            }
    }

    /// Panning while zoomed in, and swipe-to-dismiss while not — the same
    /// gesture, because at 1× there is nowhere to pan to and the drag is
    /// obviously meant to put the photo away.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomedIn {
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                } else {
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if isZoomedIn {
                    committedOffset = offset
                } else if value.translation.height > 120 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { resetPan() }
                }
            }
    }

    /// Double-tap zoom.
    ///
    /// Gated on Reduce Motion because this one animates a *scale* — the trigger
    /// Apple names first, and the only real one in the app. The zoom still
    /// happens; it just arrives rather than travels.
    private func toggleZoom() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            if isZoomedIn {
                zoom = 1
                committedZoom = 1
                resetPan()
            } else {
                zoom = 2.5
                committedZoom = 2.5
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Close")

            Spacer()

            if loaded != nil, !isOriginal {
                // Under low data the viewer opens on a 1024 thumbnail. The
                // original is one tap away, and sharing and saving wait for it:
                // handing somebody a reduced copy without saying so would be a
                // surprise they find out about later.
                Button {
                    Task { await loadOriginal() }
                } label: {
                    if isLoadingOriginal {
                        ProgressView().tint(.white)
                    } else {
                        Text("Load full photo")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
                .disabled(isLoadingOriginal)
            }

            if let fullSize, isOriginal {
                ShareLink(item: Image(uiImage: fullSize), preview: SharePreview(authorLabel, image: Image(uiImage: fullSize))) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Share this photo")

                Button {
                    Task { await saveToPhotos(fullSize) }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Save to Photos")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let outcome = saveOutcome {
                Text(outcome)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)
            }
            HStack(spacing: 6) {
                Text(authorLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !timestamp.isEmpty {
                    // The name gives way first: a long one is still recognisable
                    // cut short, a clipped time is not.
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            if let note = post.displayNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            if canReply || (replyCount ?? 0) > 0 {
                replyBar
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.45))
    }

    /// Words or a photo back, and how many people already have. More than an
    /// emoji, which is what a reaction was the only way to say (issue #304).
    private var replyBar: some View {
        HStack(spacing: 10) {
            if canReply {
                Button {
                    composingComment = true
                } label: {
                    Label("Comment", systemImage: "bubble.left")
                }
                .accessibilityHint("Sends a comment on this photo to everyone here")

                Button {
                    showCamera = true
                } label: {
                    Label("Reply with photo", systemImage: "camera")
                }
                .accessibilityHint("Takes a photo to send back")
            }

            Spacer(minLength: 0)

            if let replyCount, replyCount > 0 {
                Text(replyCount == 1 ? String(localized: "1 reply") : String(localized: "\(replyCount) replies"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
        }
        .font(.footnote.bold())
        .foregroundStyle(.white)
        .buttonStyle(.bordered)
        .tint(.white)
    }

    // MARK: Saving

    /// Asks for add-only access, which is the narrowest permission that can
    /// write a photo: it grants no ability to read the library back.
    private func saveToPhotos(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveOutcome = String(localized: "Pear'd needs permission to add to Photos.")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveOutcome = String(localized: "Saved to Photos.")
        } catch {
            saveOutcome = String(localized: "Couldn't save that photo.")
        }
    }
}

/// Words on somebody's photo, sent to everyone in the connection.
///
/// A sheet over the viewer rather than a field in it: the viewer is the photo,
/// and a keyboard coming up over it would cover the thing being talked about.
/// Half height, so the photo is still there above it.
private struct PhotoCommentSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Whose photo, as a possessive ("Ada's").
    let whose: String
    let onSend: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $text, prompt: Text("Say something about \(whose) photo…"), axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...5)
                    .foregroundStyle(PearColor.textPrimary)
                    .padding(12)
                    .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: text) { _, newValue in
                        text = PostNote.capped(newValue)
                    }
                    .accessibilityLabel("Comment")

                if text.count > 200 {
                    Text("\(PostNote.limit - text.count) characters left")
                        .font(.caption)
                        .foregroundStyle(PearColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(PearColor.background)
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let words = PostNote.normalised(text)
                        dismiss()
                        onSend(words)
                    }
                    .fontWeight(.semibold)
                    .disabled(PostNote.isEmpty(text))
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
