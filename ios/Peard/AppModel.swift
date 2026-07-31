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
        /// The privacy policy has not been agreed to. Nothing reaches the
        /// network from here — see `bootstrap()`.
        case consent
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
    ///
    /// The observer keeps the springboard badge honest. Doing it here rather
    /// than at each assignment is deliberate: `connections` is rewritten from
    /// six places — membership resolution, refresh, the local unread clear,
    /// sign-out, account deletion and the 401 path — and a badge that is only
    /// right at five of them is a badge nobody can trust.
    private(set) var connections: [Connection] = [] {
        didSet { syncBadge() }
    }
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
    /// An invite code from a link that arrived mid-launch, held until the launch
    /// has finished routing — see `handle(url:)` and `applyPendingPairCode()`.
    ///
    /// Survives the sign-in screen on purpose: a link tapped by somebody who has
    /// never opened the app sends them to sign in first, and the code has to
    /// still be there afterwards or the invite is lost at the one moment it is
    /// most likely to be used.
    ///
    /// Readable so the tests can assert it is *held* rather than applied: with
    /// no session there is nothing to redeem an invite against, so the correct
    /// behaviour is to land on sign-in with the code still in hand.
    private(set) var pendingPairCode: String?

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
    ///
    /// The privacy gate is the first thing here, and it returns before anything
    /// touches the network — not after, and not in parallel. Everything below it
    /// talks to the server: the health probe, the membership fetch, the send
    /// queue's flush. Putting the check anywhere else would mean the promise
    /// ("nothing leaves your device until you agree") was true of the sign-in
    /// button but not of launch.
    func bootstrap() async {
        phase = .loading
        guard hasAgreedToPrivacyPolicy else {
            phase = .consent
            return
        }
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
        applyPendingPairCode()
        // Anything logged while the app was closed, or while the last session was
        // offline, goes out now.
        flushSendQueue()
    }

    /// Routes to an invite code that arrived while the launch was still running.
    ///
    /// Last, so it wins over whatever membership resolution decided — which is
    /// the point: somebody who taps an invite link wants the pairing screen with
    /// the code in it, not the home screen they would have got anyway.
    private func applyPendingPairCode() {
        guard let code = pendingPairCode else { return }
        pendingPairCode = nil
        phase = .pair(prefilledCode: code)
    }

    /// Test seam for the above, which is private because nothing outside the
    /// launch sequence should be deciding when an invite code is spent.
    func applyPendingPairCodeForTesting() { applyPendingPairCode() }

    // MARK: Privacy consent

    /// Whether this installation has agreed to the current policy. A previously
    /// accepted, now-superseded version reads as false and puts the gate back.
    var hasAgreedToPrivacyPolicy: Bool {
        sharedStore.privacyConsent.hasAcceptedCurrentVersion
    }

    /// True the first time the gate is shown, false when it is back because the
    /// policy changed — the screen says different things in the two cases.
    var isFirstPrivacyPrompt: Bool { sharedStore.privacyConsent.isFirstRun }

    /// Records agreement and carries on with the launch that was interrupted.
    /// Re-entering `bootstrap` rather than duplicating its steps: the gate is a
    /// pause in the launch sequence, not a branch of it.
    func agreeToPrivacyPolicy() async {
        sharedStore.recordPrivacyConsent()
        await bootstrap()
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
        applyPendingPairCode()
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
    ///
    /// `deletingMoments` is the leave-time choice: off, the shared timeline keeps
    /// what the caller logged; on, their own moments in this one connection go
    /// with them. Scoped to this connection only — erasing everything everywhere
    /// is account deletion, which is a different button in a different place.
    func leave(connectionID: String, deletingMoments: Bool = false) async {
        do {
            try await api.leave(pairID: connectionID, deleteMoments: deletingMoments)
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

    // MARK: Read state

    /// Where the timeline draws its "new since you last looked" line, per
    /// connection, for the life of this app session.
    ///
    /// Captured once and then left alone, which is the whole trick. Marking a
    /// connection seen moves the server's stamp to now, so a divider derived
    /// from the live value would vanish the instant the home screen loaded —
    /// before the user could reach the timeline tab to see it. Freezing it at
    /// the first visit means the line stays put while they move between tabs,
    /// and is gone on the next launch, which is exactly what "since you last
    /// looked" should mean.
    private var unreadWatermarks: [String: Date] = [:]

    /// The cut-off the timeline should mark as new, or nil when there was
    /// nothing new when this connection was opened.
    func unreadWatermark(forConnection pairID: String) -> Date? {
        unreadWatermarks[pairID]
    }

    /// Marks the connection currently on screen as read, and clears its badge
    /// locally without waiting for a round trip.
    ///
    /// The local clear matters: the count comes from
    /// `GET /api/peard/connections`, which is not re-fetched on every visit, so
    /// without this the badge would sit there until something else happened to
    /// reload the list — looking at a connection and watching its "3 new" stay
    /// put reads as the app not registering the visit.
    ///
    /// A failure is deliberately silent. The stamp is idempotent and re-sent on
    /// the next visit, and there is nothing a person could usefully do about
    /// "couldn't mark as read" except see an error where they expected a
    /// timeline.
    func markSelectedConnectionSeen() async {
        guard case .home(let pairID) = phase else { return }
        guard let connection = connections.first(where: { $0.id == pairID }), connection.hasUnread else { return }

        // Only the first time this session — see `unreadWatermarks`. A second
        // visit after the stamp has moved would otherwise reset the line to
        // "now" and quietly erase it.
        if unreadWatermarks[pairID] == nil, let seen = connection.lastSeenAt {
            unreadWatermarks[pairID] = seen
        }

        clearUnreadLocally(pairID: pairID)
        try? await api.markSeen(pairID: pairID)
    }

    /// What the springboard badge should say — see `totalUnreadForBadge`, which
    /// holds the rule so it can be tested without a live server.
    var badgeCount: Int { connections.totalUnreadForBadge }

    private func syncBadge() {
        Task { [push, badgeCount] in await push.setBadgeCount(badgeCount) }
    }

    /// Rewrites one connection's count to zero in the local list.
    ///
    /// `Connection` is a value type with `let` fields, so this rebuilds the one
    /// that changed rather than mutating it — cheaper than re-fetching the list
    /// and, unlike a re-fetch, it cannot briefly show the old number again.
    private func clearUnreadLocally(pairID: String) {
        connections = connections.map { connection in
            guard connection.id == pairID, connection.hasUnread else { return connection }
            return Connection(
                pair: connection.pair,
                name: connection.name,
                created: connection.created,
                role: connection.role,
                memberCount: connection.memberCount,
                members: connection.members,
                isMuted: connection.isMuted,
                avatarFilename: connection.avatarFilename,
                unreadCount: 0
            )
        }
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

    /// Opts in or out of contact search — see
    /// `APIClient.updateDiscoverability(discoverable:phone:)`. Searching your
    /// own contacts needs none of this; it only governs whether this account
    /// can appear in someone *else's* results.
    func updateDiscoverability(discoverable: Bool, phone: String) async {
        do {
            let status = try await api.updateDiscoverability(discoverable: discoverable, phone: phone)
            profile = profile.map {
                UserProfile(
                    id: $0.id,
                    displayName: $0.displayName,
                    email: $0.email,
                    avatarFilename: $0.avatarFilename,
                    discoverable: status.discoverable,
                    phone: status.phone
                )
            }
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Sets the caller's own photo. Everybody they share a connection with sees
    /// it, so the connection list is re-read: it carries each member's avatar,
    /// including the caller's own.
    func updateProfileAvatar(jpeg data: Data) async {
        do {
            profile = try await api.uploadProfileAvatar(jpeg: data)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
    }

    /// Removes the caller's own photo, back to initials.
    func removeProfileAvatar() async {
        do {
            profile = try await api.removeProfileAvatar()
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
    }

    /// Sets a connection's photo. Any member may, exactly as any member may
    /// rename it.
    func updateConnectionAvatar(connectionID: String, jpeg data: Data) async {
        do {
            _ = try await api.uploadConnectionAvatar(pairID: connectionID, jpeg: data)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
    }

    /// Removes a connection's photo. A 1:1 falls back to the other person's, a
    /// group to its initials.
    func removeConnectionAvatar(connectionID: String) async {
        do {
            _ = try await api.removeConnectionAvatar(pairID: connectionID)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return
        }
        await refreshConnections()
    }

    // MARK: Account deletion

    /// Erases the account on the server, then tears the session down locally.
    ///
    /// The order matters: the delete needs the token, so the local cleanup can
    /// only follow it. A failure leaves the session intact and reports itself,
    /// because the alternative — signing somebody out of an account that still
    /// exists while telling them it is gone — is worse than an error message.
    ///
    /// The push registration is deleted first, and separately, so an account
    /// that has gone cannot leave a `devices` row pointed at this handset. It
    /// cascades server-side too; doing both means neither has to be trusted
    /// alone.
    ///
    /// Returns true when the account is gone, so the caller knows whether to
    /// dismiss its confirmation.
    @discardableResult
    func deleteAccount() async -> Bool {
        do {
            await push.deleteRegistration()
            try await api.deleteAccount()
        } catch let error as APIError where error.status == 404 {
            // The route is missing, which means the app is talking to a server
            // older than this feature. Worth its own message: "Not found" tells
            // somebody trying to delete their account nothing at all, and the
            // fallback the privacy policy still documents — emailing us — does
            // work. An installed app cannot assume the server has caught up
            // with it, and this is the one request where failing opaquely is
            // least acceptable.
            banner = "This server can't delete accounts in-app yet. Email \(PeardLinks.supportEmail) and we'll do it for you."
            return false
        } catch {
            banner = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return false
        }
        // Deliberately not `signOut()`: that deletes the push registration again
        // against an account that no longer exists, which just produces a 404.
        await sendQueue.removeAll()
        await refreshPendingSends()
        sessionStore.clear()
        widgetSync.clear()
        connections = []
        profile = nil
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        unreadWatermarks.removeAll()
        phase = .auth
        return true
    }

    /// Requirement 8.4 — a 401 clears the session and forces re-authentication.
    func clearSessionAndReturnToAuth() async {
        sessionStore.clear()
        widgetSync.clear()
        connections = []
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        unreadWatermarks.removeAll()
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
        unreadWatermarks.removeAll()
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
    ///
    /// A deep link is the one way into the app that skips launch routing, so the
    /// privacy gate is repeated here: an invite link tapped on a fresh install
    /// would otherwise open straight onto the pairing screen, whose first act is
    /// to redeem the code against the server.
    func handle(url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        guard hasAgreedToPrivacyPolicy else {
            phase = .consent
            return
        }
        switch link {
        case .pair(let code):
            // While the launch is still running, setting the phase here is
            // pointless: `bootstrap` sets it again the moment membership
            // resolves, and the code is gone. Hand it over instead, and let the
            // launch apply it when it has finished deciding where to land.
            guard case .loading = phase else {
                phase = .pair(prefilledCode: code)
                return
            }
            pendingPairCode = code
        case .home:
            // Requirement 19.2, 19.3 — only land on home when a pair exists.
            if case .home = phase { return }
            Task { await resolveMembership() }
        case .googleCallback(let url):
            AuthCoordinator.deliverPendingAuthorization(url: url)
        }
    }

    // MARK: Foreground

    /// Called from `PeardApp`'s `scenePhase` observer on every return to
    /// `.active`.
    ///
    /// This existed for a while with nothing calling it, which was not a no-op:
    /// the reachability callback only fires while the app is running, so a
    /// moment logged with no signal, backgrounded, and then carried back into
    /// coverage sat in the queue until the next *cold* launch or until the app
    /// happened to witness a network transition itself. The authorization status
    /// went stale the same way — turn notifications off in Settings and the app
    /// went on believing it had them.
    func applicationDidBecomeActive() async {
        guard hasAgreedToPrivacyPolicy else { return }
        await push.refreshAuthorizationStatus()
        // Coming back to the app is the other reliable moment to drain the queue:
        // the reachability callback covers a network that returns while the app is
        // running, this covers everything that changed while it was not.
        flushSendQueue()
        // And re-read the connections, which is where the unread counts live.
        //
        // The home screen has its own scenePhase hook that does this, but only
        // while the home screen exists: background the app from Settings or the
        // timeline and come back, and the rail's counts and the springboard
        // badge were whatever they had been when you left. Which tab you happen
        // to be standing on is not a sensible reason for the badge to be right
        // or wrong, so this lives at the app level where it applies either way.
        await refreshConnections()
    }
}
