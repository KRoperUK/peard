import Foundation
import PeardCore
import SwiftUI
import UIKit

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
        /// Signed in, with the connections screen showing. This is where
        /// somebody with no connections lands: an empty list they can search
        /// their contacts from, rather than a code they are made to create or
        /// enter before the app will let them past.
        case connections
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
    /// The token protected photos are fetched with. One per session, shared by
    /// every screen that draws one — see `FileTokenStore`.
    let fileTokens: FileTokenStore
    let sharedStore: SharedStore

    /// Which pear is on the home screen.
    ///
    /// Read from UIKit rather than stored: `alternateIconName` is the system's
    /// own record of what is actually set, and keeping a second copy in
    /// UserDefaults is how the two come to disagree after a restore or a
    /// reinstall.
    var appIcon: AppIconChoice = .init(alternateName: nil)

    /// Light, dark, or whatever the phone is doing.
    ///
    /// Mirrored into an observable property rather than read from the store on
    /// every body evaluation: the root view keys `preferredColorScheme` on this,
    /// and a plain `UserDefaults` read is invisible to SwiftUI — the setting
    /// would take a relaunch to show up.
    var appearance: AppearancePreference {
        didSet { sharedStore.appearance = appearance }
    }

    /// Automatic, on or off — see `LowDataPreference`. Mirrored for the same
    /// reason as `appearance`: views key on it, and a defaults read is not
    /// observable.
    var lowData: LowDataPreference {
        didSet { sharedStore.lowData = lowData }
    }

    /// Millilitres or fluid ounces — how water is drawn, never what is stored
    /// (#324). Mirrored like `appearance` so every screen redraws the moment it
    /// changes.
    var waterUnit: WaterUnit {
        didSet { sharedStore.waterUnit = waterUnit }
    }

    /// How long a tapped moment waits before it sends itself (#398). Mirrored
    /// like the rest, and read when a moment is tapped rather than on every tick,
    /// so a change applies to the next send and never moves one in flight.
    var sendWindow: SendWindow {
        didSet { sharedStore.sendWindow = sendWindow }
    }
    let widgetSync: WidgetSync
    let push: PushCoordinator
    let liveActivities: LiveActivityCoordinator
    /// Moments logged on the device but not yet accepted by the server.
    let sendQueue: SendQueue
    /// Moments the widget, Control Centre and Siri could not send, waiting to be
    /// taken into `sendQueue`; see `MomentInbox`.
    let momentInbox: MomentInbox
    /// The JPEGs behind queued photo moments; see `PendingPhotoStore`.
    let pendingPhotos: PendingPhotoStore
    /// The last-known connection list, so an offline launch is not a dead end
    /// that claims the user has no connections (#300).
    let connectionCache: ConnectionCaching
    let reachability: Reachability

    // MARK: State

    var phase: Phase = .loading
    /// Every connection the signed-in user belongs to, oldest first.
    ///
    /// The observer keeps the springboard badge honest. Doing it here rather
    /// than at each assignment is deliberate: `connections` is rewritten from
    /// six places — membership resolution, refresh, the local unread clear,
    /// sign-out, account deletion and the 401 path — and a badge that is only
    /// right at five of them is a badge nobody can trust.
    var connections: [Connection] = [] {
        didSet { syncBadge() }
    }
    /// Drives the retry control shown when membership resolution failed
    /// (Requirement 9.6).
    var membershipFailed = false
    /// When `connections` was last fetched from the server, so a list restored
    /// from the cache can say how old it is (#300).
    var connectionsUpdatedAt: Date?
    /// True while the list on screen came from the cache rather than the server,
    /// which is what makes it worth saying so.
    var connectionsFromCache = false
    /// Post to scroll to after a notification tap (Requirement 18.7).
    var focusedPostID: String?
    /// Non-blocking message shown under the current screen.
    var banner: String?
    /// Mirror of the queue's contents, so views can draw pending moments without
    /// awaiting an actor on every redraw.
    var pendingSends: [PendingSend] = []
    /// False while there is no usable network path.
    var isOnline = true
    /// True while iOS Low Data Mode is on for the network in use.
    var isNetworkConstrained = false
    /// Hidden for the rest of the session once dismissed. Not remembered past
    /// that: the notice is the only sign of why photos look soft, and somebody
    /// who forgot they turned it on deserves to be told again next launch.
    var lowDataNoticeDismissed = false
    /// The caller's own record, loaded lazily by the settings screen.
    var profile: UserProfile?

    var hasRequestedPushThisSession = false
    var flushTask: Task<Void, Never>?
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
    var pendingPairCode: String?

    init(
        config: PeardConfig = .current,
        sessionStore: KeychainSessionStore = KeychainSessionStore(),
        sharedStore: SharedStore = .shared,
        sendQueue: SendQueue? = nil,
        momentInbox: MomentInbox = .appGroup(),
        connectionCache: ConnectionCaching = FileConnectionCache.appGroup(),
        reachability: Reachability = Reachability(),
        session: URLSession? = nil
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.sharedStore = sharedStore
        self.appearance = sharedStore.appearance
        self.lowData = sharedStore.lowData
        self.waterUnit = sharedStore.waterUnit
        self.sendWindow = sharedStore.sendWindow
        let api = APIClient(baseURL: config.serverURL, tokenProvider: sessionStore, session: session)
        self.api = api
        self.fileTokens = FileTokenStore(api: api)
        self.widgetSync = WidgetSync(
            api: api, store: sharedStore, baseURL: config.serverURL,
            // The device class (iPhone / iPad) names this row in the devices
            // list (#379); the row's created date tells two of a kind apart.
            // `model` needs no entitlement and is not the user-set device name,
            // so it carries no personal data.
            deviceLabel: UIDevice.current.model
        )
        self.push = PushCoordinator(api: api, session: sessionStore, store: sharedStore)
        self.liveActivities = LiveActivityCoordinator(api: api, session: sessionStore, store: sharedStore)
        self.sendQueue = sendQueue ?? SendQueue(store: FilePendingSendStore.appGroup())
        self.momentInbox = momentInbox
        self.pendingPhotos = PendingPhotoStore.appGroup()
        self.connectionCache = connectionCache
        self.reachability = reachability

        appIcon = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)

        push.onOpenPost = { [weak self] postID in
            self?.openPost(postID)
        }
        push.onBackgroundRefresh = { [weak self] in
            await self?.performBackgroundRefresh()
        }
        push.onRegistered = { [weak self] in
            await self?.liveActivities.uploadStartToken()
        }
        // Every tab of a connection counts as its screen: they share one
        // `HomeModel`, so the refresh brings all of them up to date at once.
        push.connectionOnScreen = { [weak self] in
            guard case .home(let pairID) = self?.phase else { return nil }
            return pairID
        }
        push.onRefreshConnectionOnScreen = { [weak self] in
            await self?.onHomeRefreshRequested?()
        }
    }

    /// Set by the home screen so a silent push can re-request its posts
    /// (Requirement 18.6), and so can an alert for the connection on screen.
    var onHomeRefreshRequested: (@MainActor () async -> Void)?

    /// Set by the home screen so a return to the foreground re-reads its
    /// content — and only its content: `applicationDidBecomeActive` has already
    /// refreshed the connections and started the flush by the time it runs.
    var onHomeForegrounded: (@MainActor () async -> Void)?

    /// Set by the home screen so a moment still counting down is sent rather
    /// than abandoned when the app goes to the background (#398). Without it,
    /// the countdown task is suspended with everything else and the tap is lost.
    var onHomeBackgrounded: (@MainActor () async -> Void)?

    /// Requirement 18.6 — refresh posts, refresh the App Group container, and
    /// reload widget timelines. Also drains the send queue: a silent push is a
    /// free wake-up, and the device demonstrably has connectivity to have received
    /// it at all.
    func performBackgroundRefresh() async {
        await flushSendQueueAndWait(refreshingHome: false)
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
    func applyPendingPairCode() {
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
    var unreadWatermarks: [String: Date] = [:]

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

    func syncBadge() {
        Task { [push, badgeCount] in await push.setBadgeCount(badgeCount) }
    }

    /// Rewrites one connection's count to zero in the local list.
    ///
    /// `Connection` is a value type with `let` fields, so this rebuilds the one
    /// that changed rather than mutating it — cheaper than re-fetching the list
    /// and, unlike a re-fetch, it cannot briefly show the old number again.
    func clearUnreadLocally(pairID: String) {
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

    // MARK: Push

    func requestPushIfFirstHomeOfSession() async {
        guard !hasRequestedPushThisSession else { return }
        hasRequestedPushThisSession = true
        liveActivities.start()
        await push.requestAuthorizationIfNeeded()
    }

    func openPost(_ postID: String) {
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
        // A cold launch becomes active while `bootstrap` is still running, and
        // `bootstrap` already fetches the connections and flushes the queue —
        // doing it here as well fetched the connection list twice on every
        // launch (issue #302's audit). Nothing below is lost by waiting: the
        // home screen loads its own content when it first appears.
        guard phase != .loading else { return }
        // Coming back to the app is the other reliable moment to drain the queue:
        // the reachability callback covers a network that returns while the app is
        // running, this covers everything that changed while it was not.
        flushSendQueue()
        // And re-read the connections, which is where the unread counts live.
        // Here at the app level because which tab you happen to be standing on
        // is not a sensible reason for the rail's counts or the springboard
        // badge to be right or wrong.
        await refreshConnections()
        // Then the home screen's own content (Requirement 11.13).
        //
        // This is the only foreground path (issue #169). The home screen used
        // to run a full refresh from its own scenePhase hook as well, which
        // re-read the connections and flushed the queue a second time — and,
        // without the inactive→active guard `PeardApp` has, did all of it again
        // whenever Control Centre or a notification banner was dismissed. A
        // flush that delivers something asks for a full home refresh itself,
        // so content read here before a queued moment lands is corrected then.
        await onHomeForegrounded?()
    }

    // MARK: Background

    /// Called from `PeardApp`'s `scenePhase` observer when the app goes to the
    /// background (#398).
    ///
    /// The one job is to hand a still-counting-down moment to the home screen,
    /// which commits it to the durable queue before the app is suspended — so
    /// "tap a moment, then switch away" logs it rather than losing it. A send
    /// already held for a note is deliberately left alone: somebody who typed
    /// something meant to tap Send themselves.
    func applicationDidEnterBackground() async {
        await onHomeBackgrounded?()
    }
}

extension AppModel {
    /// Whether to behave as low-data now: the preference, applied to what the
    /// network is reporting.
    var isLowDataActive: Bool {
        lowData.isActive(systemConstrained: isNetworkConstrained)
    }

    /// The size every list thumbnail is asked for at.
    var listPhotoThumb: PhotoThumb { PhotoThumb.list(lowData: isLowDataActive) }
}

extension AppModel {
    /// What `preferredColorScheme` should be given, which is nothing at all
    /// when the answer is "ask the phone".
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension AppModel {
    /// Switches the home-screen icon.
    ///
    /// iOS shows its own "You have changed the icon" alert and there is no
    /// supported way to suppress it, so this deliberately shows nothing of its
    /// own — two confirmations for one tap is worse than the system's one.
    ///
    /// A failure is reported rather than swallowed. It means the alternate is
    /// missing from the build (see ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES
    /// in project.yml), which is a mistake somebody needs to hear about rather
    /// than a tap that silently did nothing.
    func setAppIcon(_ choice: AppIconChoice) async {
        guard choice != appIcon else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            banner = String(localized: "This device can't change the app icon.")
            return
        }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateName)
            appIcon = choice
        } catch {
            // Back to whatever is really set, so the picker cannot end up
            // showing a choice the home screen does not have.
            appIcon = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)
            banner = String(localized: "Couldn't change the icon — still using \(appIcon.title).")
        }
    }
}
