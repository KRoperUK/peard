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
    /// Moments logged on the device but not yet accepted by the server.
    let sendQueue: SendQueue
    let reachability: Reachability

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
    /// Mirror of the queue's contents, so views can draw pending moments without
    /// awaiting an actor on every redraw.
    private(set) var pendingSends: [PendingSend] = []
    /// False while there is no usable network path.
    private(set) var isOnline = true
    /// The caller's own record, loaded lazily by the settings screen.
    private(set) var profile: UserProfile?

    private var hasRequestedPushThisSession = false
    private var flushTask: Task<Void, Never>?

    init(
        config: PeardConfig = .current,
        sessionStore: KeychainSessionStore = KeychainSessionStore(),
        sharedStore: SharedStore = .shared,
        sendQueue: SendQueue? = nil,
        reachability: Reachability = Reachability()
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.sharedStore = sharedStore
        let api = APIClient(baseURL: config.serverURL, tokenProvider: sessionStore)
        self.api = api
        self.widgetSync = WidgetSync(api: api, store: sharedStore, baseURL: config.serverURL)
        self.push = PushCoordinator(api: api, session: sessionStore, store: sharedStore)
        self.sendQueue = sendQueue ?? SendQueue(store: FilePendingSendStore.appGroup())
        self.reachability = reachability

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
    /// reload widget timelines. Also drains the send queue: a silent push is a
    /// free wake-up, and the device demonstrably has connectivity to have received
    /// it at all.
    private func performBackgroundRefresh() async {
        await flushSendQueueAndWait()
        await onHomeRefreshRequested?()
        await widgetSync.sync()
    }

    var signedInUserID: String { sessionStore.userID ?? "" }

    // MARK: Launch

    /// Requirement 9.1, 9.2, 9.3.
    func bootstrap() async {
        phase = .loading
        sessionStore.load()
        await attachSendQueue()

        #if DEBUG
        await DebugSupport.logHealth(api: api)
        #endif

        guard sessionStore.hasSession else {
            phase = .auth
            return
        }
        await resolveMembership()
        // Anything logged while the app was closed, or while the last session was
        // offline, goes out now.
        flushSendQueue()
    }

    // MARK: Send queue

    /// Reads the queue into observable state and starts watching the network, so a
    /// moment logged with no signal leaves as soon as there is one.
    ///
    /// Internal rather than private so the app-target tests can drive the real
    /// path instead of a test-only hook.
    func attachSendQueue() async {
        await refreshPendingSends()
        isOnline = reachability.isOnline
        reachability.onChange { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                // Only on the way back up: going offline has nothing to send.
                if online { self.flushSendQueue() }
            }
        }
        reachability.start()
    }

    /// Copies the queue's contents into `pendingSends`.
    ///
    /// Called after every operation that can change the queue rather than through a
    /// callback registered at startup. The callback version meant the UI showed
    /// nothing at all if the registration had not happened yet — an ordering
    /// dependency with no visible symptom, which is the worst kind.
    private func refreshPendingSends() async {
        pendingSends = await sendQueue.pending
    }

    /// Adds a moment to the queue. The queue persists it before anything is sent,
    /// so the moment survives the app being killed mid-request.
    func enqueue(_ send: PendingSend) async {
        await sendQueue.enqueue(send)
        await refreshPendingSends()
    }

    /// Kicks off a flush, coalescing with one already in flight. Non-blocking so
    /// callers on the main actor (a tap, a foreground) are never held up by it.
    func flushSendQueue() {
        guard sessionStore.hasSession else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            await self?.performFlush()
        }
    }

    /// Awaits a flush. Used where the caller wants the result before redrawing.
    @discardableResult
    func flushSendQueueAndWait() async -> FlushResult {
        guard sessionStore.hasSession else { return FlushResult() }
        return await performFlush()
    }

    @discardableResult
    private func performFlush() async -> FlushResult {
        let api = self.api
        let result = await sendQueue.flush { send in
            let _: Post = try await api.create("posts", fields: send.postFields)
        }
        await refreshPendingSends()

        if result.didChangeAnything {
            // A send that landed changes the timeline, the tallies and the widget.
            await onHomeRefreshRequested?()
            widgetSync.reloadTimelines()
        }
        return result
    }

    /// Clears the failure history of abandoned sends so they are tried again.
    func retryStalledSends() async {
        await sendQueue.reviveStalled()
        await refreshPendingSends()
        await flushSendQueueAndWait()
    }

    /// Discards everything queued. Offered when a send has given up, because the
    /// alternative — a moment that can never be delivered sitting there forever —
    /// is worse than losing it deliberately.
    func discardPendingSends() async {
        await sendQueue.removeAll()
        await refreshPendingSends()
    }

    /// Pending sends for one connection, newest last.
    func pendingSends(forConnection pairID: String) -> [PendingSend] {
        pendingSends.filter { $0.pairID == pairID }
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

    // MARK: Connection settings

    /// Silences or unsilences one connection's notifications.
    ///
    /// Per connection rather than per user: with 20 connections of up to 12 people
    /// each, the useful control is "this group is too noisy", not "stop
    /// notifying me".
    func setMuted(connectionID: String, muted: Bool) async {
        do {
            try await api.setMuted(pairID: connectionID, muted: muted)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
    }

    /// Removes somebody else from a connection. Owners only, enforced server-side.
    func removeMember(connectionID: String, userID: String) async {
        do {
            try await api.removeMember(pairID: connectionID, userID: userID)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
        await widgetSync.sync()
    }

    // MARK: Profile

    /// Loads the caller's own record. Its `display_name` is what every other
    /// member sees in the switcher, the timeline and the push copy.
    func loadProfile() async {
        do {
            profile = try await api.profile()
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Sets the name other members see. An empty name is a deliberate reset back
    /// to the email-local-part fallback, not an error.
    func updateDisplayName(_ name: String) async {
        do {
            profile = try await api.updateDisplayName(name)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        // Every connection carries the caller's own name in its member list.
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
        // Queued moments are discarded here but deliberately *not* in
        // clearSessionAndReturnToAuth: a 401 can just be an expired token, and
        // the same person will sign back in and still want their moments. Signing
        // out is a decision, and a queued send carries an author id that the next
        // account cannot post under anyway.
        await sendQueue.removeAll()
        await refreshPendingSends()
        sessionStore.clear()
        widgetSync.clear()
        connections = []
        profile = nil
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
        // Coming back to the app is the other reliable moment to drain the queue:
        // the reachability callback covers a network that returns while the app is
        // running, this covers everything that changed while it was not.
        flushSendQueue()
    }
}
