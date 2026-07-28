import Foundation
import PeardCore
import SwiftUI

/// Top-level app state (Requirement 9), session lifecycle (Requirement 8),
/// deep-link handling (Requirement 19), and sign-out (Requirement 15.4).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case auth
        case pair(prefilledCode: String?)
        case home(pairID: String)

        var isHome: Bool {
            if case .home = self { return true }
            return false
        }
    }

    // MARK: Dependencies

    let config: PeardConfig
    let sessionStore: KeychainSessionStore
    let api: APIClient
    let sharedStore: SharedStore
    let widgetSync: WidgetSync
    let push: PushCoordinator

    // MARK: State

    private(set) var phase: Phase = .loading
    /// Every connection the signed-in user belongs to, oldest first.
    private(set) var connections: [Connection] = []
    /// Drives the retry control shown when membership resolution failed
    /// (Requirement 9.6).
    private(set) var membershipFailed = false
    /// Post to scroll to after a notification tap (Requirement 18.7).
    var focusedPostID: String?
    /// Non-blocking message shown under the current screen.
    var banner: String?

    private var hasRequestedPushThisSession = false

    init(
        config: PeardConfig = .current,
        sessionStore: KeychainSessionStore = KeychainSessionStore(),
        sharedStore: SharedStore = .shared
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.sharedStore = sharedStore
        let api = APIClient(baseURL: config.serverURL, tokenProvider: sessionStore)
        self.api = api
        self.widgetSync = WidgetSync(api: api, store: sharedStore, baseURL: config.serverURL)
        self.push = PushCoordinator(api: api, session: sessionStore, store: sharedStore)

        push.onOpenPost = { [weak self] postID in
            self?.openPost(postID)
        }
        push.onBackgroundRefresh = { [weak self] in
            await self?.performBackgroundRefresh()
        }
    }

    /// Set by the home screen so a silent push can re-request its posts
    /// (Requirement 18.6).
    var onHomeRefreshRequested: (@MainActor () async -> Void)?

    /// Requirement 18.6 — refresh posts, refresh the App Group container, and
    /// reload widget timelines.
    private func performBackgroundRefresh() async {
        await onHomeRefreshRequested?()
        await widgetSync.sync()
    }

    var signedInUserID: String { sessionStore.userID ?? "" }

    // MARK: Launch

    /// Requirement 9.1, 9.2, 9.3.
    func bootstrap() async {
        phase = .loading
        sessionStore.load()

        #if DEBUG
        await DebugSupport.logHealth(api: api)
        #endif

        guard sessionStore.hasSession else {
            phase = .auth
            return
        }
        await resolveMembership()
    }

    // MARK: Session

    /// Persists a session and routes from the resulting membership
    /// (Requirement 9.7). Throws when the session cannot be persisted, so the
    /// caller can show the failure (clarification Q2).
    func establish(_ session: Session) async throws {
        try sessionStore.save(token: session.token, userID: session.userID)
        await widgetSync.sync()
        await resolveMembership()
    }

    /// Requirement 9.3 – 9.6. A user may belong to several connections, so this
    /// loads all of them and lands on the remembered one.
    func resolveMembership() async {
        guard sessionStore.hasSession, sessionStore.userID != nil else {
            phase = .auth
            return
        }
        membershipFailed = false
        do {
            connections = try await api.connections()
            guard let selected = resolvedSelection() else {
                phase = .pair(prefilledCode: nil)
                return
            }
            sharedStore.selectedConnectionID = selected.id
            phase = .home(pairID: selected.id)
            await requestPushIfFirstHomeOfSession()
        } catch let error as APIError {
            if case .unauthorized = error {
                await clearSessionAndReturnToAuth()
                return
            }
            // Transport or server failure: land on pairing with a retry
            // control (Requirement 9.6).
            membershipFailed = true
            phase = .pair(prefilledCode: nil)
            banner = error.localizedDescription
        } catch {
            membershipFailed = true
            phase = .pair(prefilledCode: nil)
            banner = error.localizedDescription
        }
    }

    /// The connection the home screen should show: the remembered one while it
    /// still exists, otherwise the first.
    private func resolvedSelection() -> Connection? {
        if let remembered = sharedStore.selectedConnectionID,
           let match = connections.first(where: { $0.id == remembered }) {
            return match
        }
        return connections.first
    }

    /// The connection currently on screen.
    var selectedConnection: Connection? {
        guard case .home(let pairID) = phase else { return nil }
        return connections.first { $0.id == pairID }
    }

    /// Switches the home screen to another connection and remembers it.
    func select(connectionID: String) {
        guard connections.contains(where: { $0.id == connectionID }) else { return }
        sharedStore.selectedConnectionID = connectionID
        focusedPostID = nil
        banner = nil
        phase = .home(pairID: connectionID)
    }

    /// Opens the pairing screen to add another connection. Unlike the first
    /// visit this one is escapable, because there is a home to go back to.
    func startAddingConnection() {
        banner = nil
        phase = .pair(prefilledCode: nil)
    }

    /// True when the pairing screen was reached from an existing connection, so
    /// it can offer a way back.
    var canReturnHome: Bool { !connections.isEmpty }

    /// Returns to the last selected connection after adding was abandoned.
    func returnHome() {
        guard let selected = resolvedSelection() else { return }
        phase = .home(pairID: selected.id)
    }

    /// Re-reads the connection list without changing which one is on screen,
    /// unless the current one has gone.
    func refreshConnections() async {
        guard let userID = sessionStore.userID, !userID.isEmpty else { return }
        do {
            connections = try await api.connections()
        } catch {
            await handleIfUnauthorized(error)
            return
        }
        if case .home(let pairID) = phase, connections.contains(where: { $0.id == pairID }) {
            return
        }
        if let selected = resolvedSelection() {
            sharedStore.selectedConnectionID = selected.id
            phase = .home(pairID: selected.id)
        } else {
            sharedStore.selectedConnectionID = nil
            phase = .pair(prefilledCode: nil)
        }
    }

    /// Requirement 15.2, 15.3 — leaves one connection, keeping the others.
    func leave(connectionID: String) async {
        do {
            try await api.leave(pairID: connectionID)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
        if sharedStore.selectedConnectionID == connectionID {
            sharedStore.selectedConnectionID = nil
        }
        await refreshConnections()
        await widgetSync.sync()
    }

    /// Requirement 8.4 — a 401 clears the session and forces re-authentication.
    func clearSessionAndReturnToAuth() async {
        sessionStore.clear()
        widgetSync.clear()
        connections = []
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        phase = .auth
    }

    /// Central 401 handling for callers that surface their own messages.
    /// Returns true when the error was a 401 and the session was cleared.
    @discardableResult
    func handleIfUnauthorized(_ error: Error) async -> Bool {
        guard let apiError = error as? APIError, case .unauthorized = apiError else { return false }
        await clearSessionAndReturnToAuth()
        return true
    }

    /// Requirement 15.4 and clarification Q17: local cleanup is authoritative
    /// and always completes; the remote device-registration delete is best
    /// effort and its failure is reported rather than blocking sign-out.
    func signOut() async {
        await push.deleteRegistration()
        sessionStore.clear()
        widgetSync.clear()
        connections = []
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        phase = .auth
    }

    // MARK: Push

    private func requestPushIfFirstHomeOfSession() async {
        guard !hasRequestedPushThisSession else { return }
        hasRequestedPushThisSession = true
        await push.requestAuthorizationIfNeeded()
    }

    private func openPost(_ postID: String) {
        focusedPostID = postID
        if case .home = phase { return }
        Task { await resolveMembership() }
    }

    // MARK: Deep links

    /// Requirement 19.
    func handle(url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        switch link {
        case .pair(let code):
            phase = .pair(prefilledCode: code)
        case .home:
            // Requirement 19.2, 19.3 — only land on home when a pair exists.
            if case .home = phase { return }
            Task { await resolveMembership() }
        case .googleCallback(let url):
            AuthCoordinator.deliverPendingAuthorization(url: url)
        }
    }

    // MARK: Foreground

    func applicationDidBecomeActive() async {
        await push.refreshAuthorizationStatus()
    }
}
