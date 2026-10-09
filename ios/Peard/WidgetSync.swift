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
    func sync() async {
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
