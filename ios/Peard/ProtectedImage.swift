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
    /// Bumped by a tap on the failed state to re-run `load()` (#365). It is part
    /// of the `.task` id, so changing it re-runs the fetch the same way a new
    /// `cacheKey` does — the one explicit way back from a latched 404.
    @State private var retryToken = 0

    private var cacheKey: String { serverURL.absoluteString + path }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else if unavailable {
                // The failed state is tappable: a genuine not-found latches, but
                // the file may have arrived since (a sync that had not finished,
                // a token that has since minted), so one tap re-attempts the
                // load rather than leaving a dead placeholder (#365).
                failure()
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(PearColor.accent)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { retry() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Photo failed to load")
                    .accessibilityHint("Double tap to try again")
            } else {
                placeholder()
            }
        }
        .task(id: taskID) { await load() }
    }

    /// Re-runs the fetch after a failure. `cacheKey` has not changed, so the
    /// retry token is what makes `.task` fire again; `unavailable` is cleared so
    /// the placeholder shows while it tries, not the failed state under a spinner.
    private func retry() {
        unavailable = false
        retryToken += 1
    }

    /// What `.task` keys on: the cache key, plus the retry token so a tap
    /// re-runs the load even though the path is unchanged.
    private var taskID: String { cacheKey + "#\(retryToken)" }

    private func load() async {
        if let cached = PhotoThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            unavailable = false
            return
        }
        image = nil
        unavailable = false

        // Transient failures — a timeout, or a 401 right after the file token
        // rolled — must not turn a moment's photo permanently broken (#346).
        // Only a genuine not-found latches `unavailable`; everything else is
        // retried a few times, refreshing the token first on a 401, and left
        // retryable (the view re-runs this when it reappears) if it still fails.
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return }
            switch await fetchOnce() {
            case .loaded(let decoded):
                guard !Task.isCancelled else { return }
                image = decoded
                unavailable = false
                return
            case .gone:
                // The one case that is genuinely, permanently gone.
                if !Task.isCancelled { unavailable = true }
                return
            case .cancelled:
                return
            case .retry:
                // Fall through to the backoff and try again.
                break
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: backoff(attempt))
            }
            // Out of attempts: leave it retryable (placeholder), do not latch —
            // a later reappearance re-runs load() and may well succeed.
        }
    }

    /// The outcome of one load attempt: a decoded image, a permanent not-found,
    /// a cancellation, or a transient failure worth retrying.
    private enum Attempt {
        case loaded(UIImage)
        case gone
        case cancelled
        case retry
    }

    /// One fetch, classified so `load()` can decide whether to latch, stop, or
    /// retry. A 401 clears the token here so the next attempt mints a fresh one.
    private func fetchOnce() async -> Attempt {
        guard let token = await app.fileTokens.current() else {
            // No token at all (signed out, or the mint failed): retryable.
            return .retry
        }
        guard let url = URL(string: serverURL.absoluteString + FileTokenStore.decorate(path, token: token)) else {
            return .gone
        }
        do {
            let data = try await APIClient.data(from: url)
            guard let decoded = UIImage(data: data) else {
                // 2xx but undecodable bytes: a broken file, not transient.
                return .gone
            }
            PhotoThumbnailCache.shared.store(decoded, for: cacheKey)
            return .loaded(decoded)
        } catch let error as APIError {
            switch error {
            case .cancelled:
                return .cancelled
            case .server(let status, _) where status == 404 || status == 410:
                return .gone
            case .unauthorized:
                // Likely the token rolled under us: drop it so the next attempt
                // mints a fresh one, then retry.
                await app.fileTokens.clear()
                return .retry
            default:
                return .retry
            }
        } catch {
            return .retry
        }
    }

    /// Growing delay between retries: ~0.3s, ~0.9s. Short enough that a photo
    /// that recovers does so while the row is still on screen.
    private func backoff(_ attempt: Int) -> UInt64 {
        let seconds = 0.3 * pow(3, Double(attempt))
        return UInt64(seconds * 1_000_000_000)
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
