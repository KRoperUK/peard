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

    /// Built at load time rather than up front, because the token has to be
    /// fetched: `posts.media` is protected, and the path alone is a 404.
    private func url(token: String) -> URL? {
        guard let path = post.mediaPath() else { return nil }
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
            .animation(.easeInOut(duration: 0.2), value: isZoomedIn)
        }
        .statusBarHidden()
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
                Text("📷").font(.system(size: 44))
                Text("This photo couldn't be loaded.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        } else {
            ProgressView()
                .tint(.white)
                .task { await load() }
        }
    }

    /// Loaded here rather than with `AsyncImage` because the same bytes are
    /// needed twice: once to draw, once to hand to the share sheet or the photo
    /// library. `AsyncImage` gives a `SwiftUI.Image` and no way back to the data.
    ///
    /// A non-2xx is treated as a failure rather than decoded: PocketBase answers
    /// a missing file with a JSON error body, and `UIImage(data:)` would simply
    /// return nil on it, which reads the same as a corrupt photo.
    private func load() async {
        guard let token = await app.fileTokens.current(), let url = url(token: token) else {
            failed = true
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data) else {
                failed = true
                return
            }
            fullSize = image
            loaded = Image(uiImage: image)
        } catch {
            failed = true
        }
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
                    withAnimation(.easeOut(duration: 0.2)) { resetPan() }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
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

            if let fullSize {
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
                if !timestamp.isEmpty {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }
            if let note = post.displayNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.45))
    }

    // MARK: Saving

    /// Asks for add-only access, which is the narrowest permission that can
    /// write a photo: it grants no ability to read the library back.
    private func saveToPhotos(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveOutcome = "Pear'd needs permission to add to Photos."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveOutcome = "Saved to Photos."
        } catch {
            saveOutcome = "Couldn't save that photo."
        }
    }
}
