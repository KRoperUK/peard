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

    /// Set by the app model so a `content-available` push can refresh the
    /// timeline, and a notification tap can focus a post.
    var onBackgroundRefresh: (@MainActor () async -> Void)?
    var onOpenPost: (@MainActor (String) -> Void)?

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(api: APIClient, session: KeychainSessionStore, store: SharedStore, center: UNUserNotificationCenter = .current()) {
        self.api = api
        self.session = session
        self.store = store
        self.center = center
    }

    // MARK: Notification categories

    /// Identifier of the category the server tags a new-moment push with
    /// (`push.momentCategory` server-side) — this is what makes iOS offer the
    /// reaction actions below instead of a plain banner.
    static let momentCategoryIdentifier = "MOMENT"
    private static let reactionActionPrefix = "REACT_"

    /// Registers the reaction quick actions so a new-moment notification can
    /// be reacted to without opening the app. Safe to call before
    /// authorization is granted or even decided — it only shapes what a
    /// notification looks like once one is actually shown.
    static func registerNotificationCategories(center: UNUserNotificationCenter = .current()) {
        let actions = ReactionKind.allCases.map { kind in
            UNNotificationAction(
                identifier: reactionActionPrefix + kind.rawValue,
                title: "\(kind.emoji) \(kind.accessibilityLabel)",
                options: []
            )
        }
        let category = UNNotificationCategory(
            identifier: momentCategoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Records a reaction fired from a notification's quick actions. Mirrors
    /// `HomeModel.react(kind:)` but has no view to update or error to show —
    /// this can run with no UI on screen at all, so it is best effort.
    func handleNotificationAction(_ actionIdentifier: String, postID: String) async {
        guard
            actionIdentifier.hasPrefix(Self.reactionActionPrefix),
            !postID.isEmpty,
            let userID = session.userID, !userID.isEmpty
        else { return }

        let kind = ReactionKind(rawValue: String(actionIdentifier.dropFirst(Self.reactionActionPrefix.count)))
        do {
            let _: Reaction = try await api.create("reactions", fields: [
                "post": postID,
                "user": userID,
                "kind": kind.rawValue,
            ])
        } catch {
            // Nowhere to surface a failure from here; the in-app reaction
            // picker on the post itself still works.
        }
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
            let fields = ["user": userID, "platform": "ios", "push_token": token]
            if let existing {
                let _: Device = try await api.update("devices", id: existing.id, fields: fields)
            } else {
                let _: Device = try await api.create("devices", fields: fields)
            }
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

    /// The user tapped a notification (Requirement 18.7).
    func handleNotificationSelection(postID: String) {
        guard !postID.isEmpty else { return }
        onOpenPost?(postID)
    }
}
