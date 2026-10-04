import PeardCore
import SwiftUI
import UIKit

/// A photo the server will not hand over without a token.
///
/// `posts.media` is a protected file field: its bytes are served only with a
/// `?token=` minted from the signed-in account, and only to somebody the post's
/// view rule admits. So every photo in the app goes through here rather than
/// building a URL from the path alone, which now 404s.
///
/// The token is resolved in a `.task` rather than read synchronously because
/// the first one has to be fetched. Rows that scroll back into view re-run it
/// and get the cached token straight back — `FileTokenStore` holds one per
/// session and dedupes concurrent misses, so a screenful of photos costs one
/// request, not one each.
///
/// Not `AsyncImage`, whose only cache is `URLCache` — and the server sends
/// these with `Cache-Control: no-store`, rightly, since they are private. So
/// every row that scrolled back into view, and every return to the tab,
/// downloaded its thumbnail again (issue #302's audit). `PhotoThumbnailCache`
/// keeps them in memory for the session instead, keyed on the path without the
/// token, the same way `AvatarImageCache` does for faces.
struct ProtectedImage<Placeholder: View, Failure: View>: View {
    @Environment(AppModel.self) private var app

    let serverURL: URL
    /// Path with any query already on it — `?thumb=512x512` is the usual one.
    let path: String
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var image: UIImage?
    @State private var unavailable = false

    private var cacheKey: String { serverURL.absoluteString + path }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else if unavailable {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        if let cached = PhotoThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            unavailable = false
            return
        }
        image = nil
        unavailable = false
        // No token means no photo. Signed out, or the server said no — either
        // way the failure view is the honest answer, and it is the same one a
        // missing file gives.
        guard
            let token = await app.fileTokens.current(),
            let url = URL(string: serverURL.absoluteString + FileTokenStore.decorate(path, token: token)),
            let data = try? await APIClient.data(from: url),
            let decoded = UIImage(data: data)
        else {
            // A row scrolled away mid-download is not a failed photo.
            if !Task.isCancelled { unavailable = true }
            return
        }
        PhotoThumbnailCache.shared.store(decoded, for: cacheKey)
        guard !Task.isCancelled else { return }
        image = decoded
    }
}

/// In-memory photo thumbnails for the session; see `ProtectedImage`.
///
/// Keyed by path including the thumb size, so a 256 fetched under Low Data
/// Mode is never served where a 512 was asked for. Bounded in bytes rather than
/// count: a 512 thumbnail decodes to about a megabyte, and a long timeline
/// scrolled end to end should not keep all of them.
final class PhotoThumbnailCache {
    static let shared = PhotoThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 48 << 20
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
