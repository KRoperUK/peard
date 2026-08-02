import PeardCore
import SwiftUI
// UIApplicationDelegate's remote-notification callback hands over a
// non-Sendable [AnyHashable: Any]; @preconcurrency accepts that pre-concurrency
// signature instead of warning at every conformance.
@preconcurrency import UIKit
import UserNotifications

@main
struct PeardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // nil for `.system`, which is what hands the decision back to
                // the phone — passing a scheme unconditionally would pin the
                // app to whatever it was last set to and ignore the setting
                // somebody has already made once, at the system level.
                .preferredColorScheme(model.preferredColorScheme)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                    // After bootstrap, so a cold launch from a quick action has
                    // a loaded session to log against.
                    appDelegate.performPendingShortcut()
                }
                .onOpenURL { url in
                    model.handle(url: url)
                }
                // Universal links arrive as a user activity rather than through
                // `onOpenURL`: that one is for the `peard://` scheme and for a
                // tap in another app, and an https link tapped in Safari or
                // Messages comes down this path instead. Both end in
                // `handle(url:)`, which knows the two shapes.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    model.handle(url: url)
                }
        }
        // Every return to the foreground, not just the first launch. `.task`
        // above runs once per window; without this, `applicationDidBecomeActive`
        // was defined and never called, so a moment queued offline waited for a
        // cold launch and the notification-authorization status went stale the
        // moment somebody changed it in Settings.
        .onChange(of: scenePhase) { previous, phase in
            guard phase == .active, previous != .active else { return }
            Task { await model.applicationDidBecomeActive() }
            // Rebuilt on every foreground: the labels come from
            // MomentCatalogue, and the menu is otherwise whatever it was when
            // the app was installed.
            QuickActions.install()
        }
    }
}

/// Root routing between the phases (Requirement 9), with the privacy gate ahead
/// of all of them — see `PrivacyConsentView`.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(PearColor.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PearColor.background)
            case .consent:
                PrivacyConsentView()
            case .auth:
                AuthView()
            case .connections:
                ConnectionsView(api: app.api)
            case .pair(let prefilledCode):
                PairView(prefilledCode: prefilledCode)
            case .home(let pairID):
                MainTabView(model: HomeModel(app: app, pairID: pairID))
                    .id(pairID)
            }
        }
        .pearAnimation(value: phaseIdentity)
        // The colour scheme is applied above this, on the window group, so it
        // reaches sheets and full-screen covers too — those are presented
        // outside this hierarchy and would otherwise keep the system's
        // appearance while the screen behind them changed. Requirement 20.3
        // (the system setting wins) still holds by default: the override is
        // opt-in, and `.system` passes nil straight back to the phone.
    }

    private var phaseIdentity: String {
        switch app.phase {
        case .loading: return "loading"
        case .consent: return "consent"
        case .auth: return "auth"
        case .connections: return "connections"
        case .pair: return "pair"
        case .home(let pairID): return "home-\(pairID)"
        }
    }
}

/// APNs plumbing (Requirement 18).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushCoordinator.registerNotificationCategories()
        QuickActions.install()

        // A launch *from* a quick action delivers it here rather than through
        // the delegate callback below, and returning false suppresses that
        // second delivery — which would otherwise log the moment twice.
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            pendingShortcut = item
            return false
        }
        return true
    }

    /// Held when the app was launched cold by a quick action, because at that
    /// point there is no session loaded and nothing to log against yet.
    private var pendingShortcut: UIApplicationShortcutItem?

    /// A quick action while the app was already running.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(perform(shortcutItem))
    }

    /// Logs the moment a quick action asked for.
    ///
    /// Straight through `MomentLogging`, the same path the widget's buttons and
    /// Siri take: it authenticates with the App Group's token rather than the
    /// session, so it works before the app has finished launching and needs no
    /// screen.
    @discardableResult
    func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let moment = QuickActions.moment(for: item) else { return false }
        Task {
            await MomentLogging.perform(
                kind: moment.kind,
                // No connection: the same "whichever is liveliest" fallback an
                // unconfigured widget uses. A quick action is fired from the
                // home screen, which has no context to choose from.
                pairID: nil,
                emoji: moment.emoji,
                label: moment.label
            )
            await model?.applicationDidBecomeActive()
        }
        return true
    }

    /// Runs a shortcut that arrived with a cold launch, once there is a model.
    func performPendingShortcut() {
        guard let pendingShortcut else { return }
        self.pendingShortcut = nil
        perform(pendingShortcut)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await model?.push.register(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Nothing to do: the app keeps working without remote notifications
        // (Requirement 18.8).
    }

    /// Silent `content-available` push (Requirement 18.6). The completion-handler
    /// form is used so the non-Sendable payload is reduced to a `Bool` here,
    /// before any actor boundary is crossed.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let contentAvailable = (aps?["content-available"] as? Int) == 1
            || (aps?["content-available"] as? Bool) == true
        Task { @MainActor in
            completionHandler(await refreshInBackground(contentAvailable: contentAvailable))
        }
    }

    private func refreshInBackground(contentAvailable: Bool) async -> UIBackgroundFetchResult {
        guard let model else { return .noData }
        return await model.push.handleBackgroundNotification(contentAvailable: contentAvailable)
    }

    /// The user tapped a notification, or one of its quick actions
    /// (Requirement 18.7).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let postID = response.notification.request.content.userInfo["post_id"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await openPost(postID)
        } else {
            await reactFromNotification(actionIdentifier: response.actionIdentifier, postID: postID)
        }
    }

    private func openPost(_ postID: String?) {
        guard let postID, !postID.isEmpty else { return }
        model?.push.handleNotificationSelection(postID: postID)
    }

    private func reactFromNotification(actionIdentifier: String, postID: String?) async {
        guard let postID, !postID.isEmpty else { return }
        await model?.push.handleNotificationAction(actionIdentifier, postID: postID)
    }

    /// Show alerts while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
