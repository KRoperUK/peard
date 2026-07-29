import PeardCore
import SwiftUI
import UIKit

/// Somebody's face, or a group's.
///
/// Falls back to initials over a colour derived from the record id, so a rail of
/// avatars is scannable before any photo has loaded and stays scannable for people
/// who never upload one. The colour is a property of the id rather than the name,
/// so renaming a group does not recolour it and two people called Sam are not the
/// same colour.
///
/// People are circles and groups are squircles. That is the whole visual grammar:
/// it survives being 32 points wide, needs no legend, and does not depend on
/// colour, which matters because a group photo of four faces is indistinguishable
/// from one face at this size.
struct AvatarView: View {
    let avatar: Avatar
    let serverURL: URL
    var size: CGFloat = 44
    var thumb: Avatar.Thumb = .small
    /// Drawn around the avatar when it is the selected one.
    var ringColor: Color?

    @State private var image: UIImage?
    @State private var isLoading = false

    private var url: URL? { avatar.url(base: serverURL, thumb: thumb) }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(PearColor.divider.opacity(0.6), lineWidth: 0.5)
            }
            .overlay {
                if let ringColor {
                    shape.strokeBorder(ringColor, lineWidth: 2.5)
                }
            }
            // Deliberately not `AsyncImage`. That loads once per view identity and
            // does not restart when its `url` changes, so replacing a group photo
            // left every rail tile showing the previous one until the app was
            // relaunched — and `.id(url)` did not dislodge it either. Verified from
            // the server's request log: no fetch of the new file was ever made,
            // while a diagnostic in `HomeView.body` proved the new filename had
            // reached the view. `task(id:)` re-runs when the id changes, which is
            // the guarantee this needs.
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if isLoading {
            placeholder.overlay(ProgressView().scaleEffect(0.6))
        } else {
            // A photo that will not load is not the same as no photo, but an error
            // glyph in a rail is noise: fall back to what the subject would have
            // looked like without one.
            placeholder
        }
    }

    private var placeholder: some View {
        Color(rgb: AvatarPalette.colours[avatar.placeholder.colourIndex])
            .overlay {
                Text(avatar.placeholder.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
    }

    private var shape: AnyInsettableShape {
        avatar.placeholder.isGroup
            ? AnyInsettableShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            : AnyInsettableShape(Circle())
    }

    private func load() async {
        guard let url else {
            image = nil
            isLoading = false
            return
        }
        if let cached = AvatarImageCache.shared.image(for: url) {
            image = cached
            isLoading = false
            return
        }
        // Clear first: keeping the previous photo on screen while a *different* one
        // loads is how the stale-avatar bug looked to the user.
        image = nil
        isLoading = true
        defer { isLoading = false }

        guard
            let data = try? await APIClient.data(from: url),
            let decoded = UIImage(data: data)
        else { return }
        AvatarImageCache.shared.store(decoded, for: url)
        guard !Task.isCancelled else { return }
        image = decoded
    }
}

/// In-memory avatar cache, so scrolling the rail or reopening a tab does not
/// re-fetch every face.
///
/// Keyed by the full URL including the thumb size, so the 46-point rail and the
/// 60-point settings row are separate entries rather than one of them being served
/// the wrong resolution. Bounded by count and by bytes: an avatar is small, but a
/// user in 20 connections of 12 people has 240 of them.
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 16 << 20
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// Type-erased `InsettableShape`, so one property can hand back either a circle or
/// a squircle and `strokeBorder` still resolves. SwiftUI ships `AnyShape` but not
/// an insettable one, and `stroke` instead of `strokeBorder` draws the ring
/// straddling the edge, which reads as a halo at these sizes.
struct AnyInsettableShape: InsettableShape {
    private let makePath: @Sendable (CGRect) -> Path
    private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
        makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { makePath(rect) }

    func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}
