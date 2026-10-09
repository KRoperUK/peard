import Foundation
import PeardCore
import UIKit
import UserNotifications
import WidgetKit

/// Notification authorization, APNs registration, and received-notification
/// handling (Requirement 18).
@MainActor
@Observable
final class PushCoordinator {
    private let api: APIClient
    private let session: KeychainSessionStore
    private let store: SharedStore
    private let center: UNUserNotificationCenter
    /// Durable queue for reactions tapped from a notification (#366): a tap in a
    /// background launch with no signal is persisted and retried, not dropped.
    private let reactionQueue: ReactionQueue

    /// Set by the app model so a `content-available` push can refresh the
    /// timeline, and a notification tap can focus a post.
    var onBackgroundRefresh: (@MainActor () async -> Void)?
    var onOpenPost: (@MainActor (String) -> Void)?
    /// Called once this device's `devices` row exists, for anything that has to
    /// hang off it — the Live Activity push-to-start token.
    var onRegistered: (@MainActor () async -> Void)?
    /// The connection whose screens are showing, if any, and how to bring them
    /// up to date — so an alert about it can be folded into the screen rather
    /// than drawn over it. See `foregroundPresentation(for:)`.
    var connectionOnScreen: (@MainActor () -> String?)?
    var onRefreshConnectionOnScreen: (@MainActor () async -> Void)?

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(api: APIClient, session: KeychainSessionStore, store: SharedStore, center: UNUserNotificationCenter = .current()) {
        self.api = api
        self.session = session
        self.store = store
        self.center = center
        self.reactionQueue = ReactionQueue(store: FilePendingReactionStore.appGroup())
    }

    // MARK: Notification categories

    /// Identifier of the category the server tags a new-moment push with
    /// (`push.momentCategory` server-side) — this is what makes iOS offer the
    /// reaction actions below instead of a plain banner.
    static let momentCategoryIdentifier = "MOMENT"
    /// The same without "Me too", for a photo on its own or a reply — a post
    /// with no moment to log back (`push.postCategory` server-side).
    static let postCategoryIdentifier = "POST"

    /// Registers the quick actions so a new-moment notification can be
    /// answered without opening the app: "Me too", a typed reply, and the
    /// reactions. Safe to call before authorization is granted or even
    /// decided — it only shapes what a notification looks like once one is
    /// actually shown.
    ///
    /// "Me too" carries no emoji, though "🍺 Me too" would read better: a
    /// category's actions are fixed here, once, and cannot differ from one
    /// notification to the next. The notification above it already says which
    /// moment it is.
    static func registerNotificationCategories(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(notificationCategories())
    }

    static func notificationCategories() -> Set<UNNotificationCategory> {
        let reactions = ReactionKind.allCases.map { kind in
            UNNotificationAction(
                identifier: NotificationReaction.actionIdentifier(for: kind),
                title: "\(kind.emoji) \(kind.accessibilityLabel)",
                options: []
            )
        }
        let meToo = UNNotificationAction(
            identifier: NotificationAnswer.meTooIdentifier,
            title: "Me too",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "plus.circle")
        )
        let reply = UNTextInputNotificationAction(
            identifier: NotificationAnswer.replyIdentifier,
            title: "Reply",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Say something back"
        )
        return [
            UNNotificationCategory(
                identifier: momentCategoryIdentifier,
                actions: [meToo, reply] + reactions,
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: postCategoryIdentifier,
                actions: [reply] + reactions,
                intentIdentifiers: [],
                options: []
            ),
        ]
    }

    /// Records a reaction fired from a notification's quick actions, durably
    /// (#366). This can run in a background launch with no UI and often no
    /// signal, so the reaction is persisted *before* the send is attempted and
    /// removed only once it lands — a tap that cannot reach the server now is
    /// retried on the next launch rather than dropped (the old path made one
    /// `try?` and lost it). Idempotent server-side, so a retry is safe.
    func handleNotificationReaction(_ reaction: NotificationReaction) async {
        guard let userID = session.userID, !userID.isEmpty else { return }
        let pending = PendingReaction(postID: reaction.postID, userID: userID, kind: reaction.kind)
        await reactionQueue.enqueue(pending)

        let api = self.api
        let sent = await reaction.send(userID: userID) { fields in
            let _: Reaction = try await api.create("reactions", fields: fields)
        }
        if sent {
            await reactionQueue.remove(id: pending.id)
        }
        // If it did not send, it stays queued; flushPendingReactions drains it
        // on the next launch or foreground.
    }

    /// Sends any reactions a past notification tap could not deliver (#366).
    /// Called on launch and foreground, beside the moment send queue's flush.
    /// Returns true when something reached the server, so the caller can refresh.
    @discardableResult
    func flushPendingReactions() async -> Bool {
        let api = self.api
        let delivered = await reactionQueue.drain { fields in
            let _: Reaction = try await api.create("reactions", fields: fields)
        }
        return delivered > 0
    }

    // MARK: Authorization

    /// Requests authorization at most once per installation unless the user
    /// explicitly asks again (Requirement 18.1, 18.9).
    func requestAuthorizationIfNeeded(userInitiated: Bool = false) async {
        await refreshAuthorizationStatus()

        if !userInitiated && store.hasRequestedNotificationAuthorization {
            // Already asked once; only re-register if the user has since
            // granted permission in Settings.
            if authorizationStatus == .authorized || authorizationStatus == .provisional {
                registerWithAPNs()
            }
            return
        }

        store.hasRequestedNotificationAuthorization = true
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                registerWithAPNs()
            }
            // Denial is inert: every feature that does not need remote
            // notifications keeps working (Requirement 18.8).
        } catch {
            // Treat an authorization error the same as a denial.
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// True when notification-dependent controls should be offered
    /// (Requirement 18.8, clarification Q18).
    var notificationsAvailable: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private func registerWithAPNs() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: Registration

    /// Upserts the `devices` record for this device (Requirement 18.3, 18.4).
    func register(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let userID = session.userID, !userID.isEmpty else { return }
        store.devicePushToken = token

        do {
            let existing = try await api.first(
                "devices",
                of: Device.self,
                filter: PeardFilter.equals("push_token", token)
            )
            let fields = Device.registrationFields(user: userID, pushToken: token)
            if let existing {
                let _: Device = try await api.update("devices", id: existing.id, fields: fields)
            } else {
                let _: Device = try await api.create("devices", fields: fields)
            }
            await onRegistered?()
        } catch {
            // Registration is retried the next time APNs hands us a token.
        }
    }

    /// Deletes this device's registration (Requirement 18.5). Best effort: the
    /// local sign-out must not depend on the network.
    func deleteRegistration() async {
        guard let token = store.devicePushToken, !token.isEmpty else { return }
        defer { store.devicePushToken = nil }
        do {
            if let existing = try await api.first(
                "devices",
                of: Device.self,
                filter: PeardFilter.equals("push_token", token)
            ) {
                try await api.delete("devices", id: existing.id)
            }
        } catch {
            // Reported by the caller; the local session is cleared regardless.
        }
    }

    /// Forgets this device's registration without asking the server, for
    /// account deletion: the server removes the account's `devices` rows with
    /// it, and the deleted account's token can no longer ask for anything.
    func forgetRegistration() {
        store.devicePushToken = nil
    }

    // MARK: Badge

    /// Sets the springboard badge.
    ///
    /// Nothing did this before read state, and the omission was the same bug the
    /// count itself had: iOS only changes a badge when a push carries a new one
    /// or the app sets it. The server sends an accurate number with every alert,
    /// then the user opens the app, reads everything — and the icon keeps saying
    /// "3" until somebody else happens to post. The app knows the answer the
    /// moment it loads its connections, so it says so.
    ///
    /// Best effort by design: a denied badge permission makes this a no-op, and
    /// that is not worth telling anybody about.
    func setBadgeCount(_ count: Int) async {
        try? await center.setBadgeCount(max(count, 0))
    }

    // MARK: Received notifications

    /// Silent `content-available` push (Requirement 18.6).
    func handleBackgroundNotification(contentAvailable: Bool) async -> UIBackgroundFetchResult {
        guard contentAvailable else { return .noData }
        guard let refresh = onBackgroundRefresh else {
            WidgetCenter.shared.reloadAllTimelines()
            return .noData
        }
        await refresh()
        WidgetCenter.shared.reloadAllTimelines()
        return .newData
    }

    /// How an alert that arrives with the app open is shown.
    ///
    /// Normally as a banner, as it always was. But one for the connection on
    /// screen was a banner over the very screen it was about, which then went
    /// on showing the old moment until the next poll — so that one is not
    /// shown at all: the screen refreshes and the moment appears in it instead.
    /// Not added to Notification Centre either, since it has been seen.
    ///
    /// A light tap stands in for the banner. Without anything, a moment could
    /// land while somebody was reading another part of the screen and never be
    /// noticed; with the alert's sound, a phone that is already in somebody's
    /// hand chimes at them in a quiet room for something they are looking at.
    /// A haptic says "that just changed" and nothing more.
    ///
    /// The refresh is started, not awaited: the system is waiting on the
    /// answer, and it has nothing to do with how long a fetch takes.
    func foregroundPresentation(for push: MomentPush?) -> UNNotificationPresentationOptions {
        guard let push, push.isFor(connectionOnScreen: connectionOnScreen?()) else {
            return [.banner, .sound]
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let refresh = onRefreshConnectionOnScreen {
            Task { await refresh() }
        }
        return []
    }

    /// The user tapped a notification (Requirement 18.7).
    func handleNotificationSelection(postID: String) {
        guard !postID.isEmpty else { return }
        onOpenPost?(postID)
    }
}
