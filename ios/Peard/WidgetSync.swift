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
            reloadTimelines()
        } catch {
            // Widget sync is opportunistic; the app works without the widget.
        }
    }

    /// Removes the token and refreshes timelines (Requirement 16.4).
    func clear() {
        store.removeWidgetToken()
        reloadTimelines()
    }

    func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
