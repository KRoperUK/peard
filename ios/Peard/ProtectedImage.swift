import PeardCore
import SwiftUI

/// An `AsyncImage` for a photo the server will not hand over without a token.
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
struct ProtectedImage<Placeholder: View, Failure: View>: View {
    @Environment(AppModel.self) private var app

    let serverURL: URL
    /// Path with any query already on it — `?thumb=512x512` is the usual one.
    let path: String
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var url: URL?
    @State private var unavailable = false

    var body: some View {
        Group {
            if unavailable {
                failure()
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                    case .failure:
                        failure()
                    default:
                        placeholder()
                    }
                }
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            guard let token = await app.fileTokens.current() else {
                // No token means no photo. Signed out, or the server said no —
                // either way the failure view is the honest answer, and it is
                // the same one a missing file gives.
                unavailable = true
                return
            }
            unavailable = false
            url = URL(string: serverURL.absoluteString + FileTokenStore.decorate(path, token: token))
        }
    }
}
