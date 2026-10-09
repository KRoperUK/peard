import Foundation
import PeardCore
import WidgetKit

/// Issues the widget token and hands it to the App Group container
/// (Requirement 16).
@MainActor
final class WidgetSync {
    private let api: APIClient
    private let store: SharedStore
    private let baseURL: URL

    init(api: APIClient, store: SharedStore, baseURL: URL) {
        self.api = api
        self.store = store
        self.baseURL = baseURL
    }

    /// Best-effort by design: a failure leaves the container untouched and the
    /// session alive (Requirement 16.3).
    ///
    /// Reuses the token this device already holds when it is still live
    /// server-side, so a sync does not mint a fresh row every time (which left
    /// the devices screen showing a pile of "ios-widget" entries, #367). It only
    /// mints when there is nothing to reuse: no stored token, or the stored one
    /// is gone (revoked or expired, so absent from the live list). A failure of
    /// the liveness check while we still hold a token is treated as "reuse it" —
    /// re-minting on a transient network blip is exactly the pile-up we are
    /// avoiding, and a genuinely dead token is caught on the next sync.
    func sync() async {
        if store.widgetToken?.isEmpty == false, let id = store.widgetTokenID, !id.isEmpty {
            if await storedTokenIsLive(id: id) {
                WatchSync.shared.update(WatchCredentials(store: store))
                reloadTimelines()
                return
            }
        }
        do {
            let issue = try await api.issueWidgetToken()
            store.writeWidgetCredentials(token: issue.token, baseURL: baseURL)
            store.widgetTokenID = issue.id
            WatchSync.shared.update(WatchCredentials(store: store))
            reloadTimelines()
        } catch {
            // Widget sync is opportunistic; the app works without the widget.
        }
    }

    /// Whether the row this device minted is still in the caller's live token
    /// list. A network failure returns `true` so a transient blip reuses the
    /// token rather than minting another; a dead token is absent from the list
    /// and returns `false`, which drives a fresh mint.
    private func storedTokenIsLive(id: String) async -> Bool {
        do {
            return try await api.widgetTokens().contains { $0.id == id }
        } catch {
            return true
        }
    }

    /// Removes the token and refreshes timelines (Requirement 16.4).
    ///
    /// Revokes the token server-side first so sign-out actually invalidates the
    /// credential rather than only forgetting the local copy (#340). Best-effort:
    /// the server also expires and caps tokens, so a missed revoke is bounded,
    /// and the local removal happens regardless.
    func clear() {
        if let token = store.widgetToken, !token.isEmpty {
            let api = api
            Task { try? await api.revokeWidgetToken(token) }
        }
        store.removeWidgetToken()
        WatchSync.shared.update(nil)
        reloadTimelines()
    }

    func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
