import Foundation

/// Read/write access to the App Group container shared by the app and the
/// widget, replacing the `PearShared` Expo native module (Requirement 16.5).
///
/// Keys match the ones the React Native build wrote, so an already-installed
/// widget keeps working after the migration.
public final class SharedStore: @unchecked Sendable {
    public enum Key {
        public static let widgetToken = "widgetToken"
        public static let apiBaseURL = "apiBaseUrl"
        public static let notificationAuthorizationRequested = "notificationAuthorizationRequested"
        public static let devicePushToken = "devicePushToken"
        public static let selectedConnectionID = "selectedConnectionId"
        public static let pendingWidgetLog = "pendingWidgetLog"
        public static let privacyPolicyAcceptedVersion = "privacyPolicyAcceptedVersion"
        public static let privacyPolicyAcceptedAt = "privacyPolicyAcceptedAt"
    }

    public static let appGroupIdentifier = "group.com.peard.app"

    public static let shared = SharedStore()

    private let defaults: UserDefaults?

    public init(suiteName: String = SharedStore.appGroupIdentifier) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    /// Injection point for tests.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// True when the App Group container is reachable. False means the
    /// entitlement is missing.
    public var isAvailable: Bool { defaults != nil }

    // MARK: Widget credentials

    public var widgetToken: String? {
        get { defaults?.string(forKey: Key.widgetToken) }
        set { set(newValue, forKey: Key.widgetToken) }
    }

    public var apiBaseURLString: String? {
        get { defaults?.string(forKey: Key.apiBaseURL) }
        set { set(newValue, forKey: Key.apiBaseURL) }
    }

    public var apiBaseURL: URL? {
        guard let apiBaseURLString, let url = URL(string: apiBaseURLString) else { return nil }
        return url
    }

    /// Writes both credentials the widget needs (Requirement 16.2).
    public func writeWidgetCredentials(token: String, baseURL: URL) {
        widgetToken = token
        apiBaseURLString = baseURL.absoluteString
    }

    /// Removes the token but keeps the base URL (Requirement 16.4).
    public func removeWidgetToken() {
        defaults?.removeObject(forKey: Key.widgetToken)
    }

    // MARK: Connections

    /// The connection the home screen last showed, so a user in several lands
    /// back where they left off. Not auth material.
    public var selectedConnectionID: String? {
        get { defaults?.string(forKey: Key.selectedConnectionID) }
        set { set(newValue, forKey: Key.selectedConnectionID) }
    }

    // MARK: Widget optimistic feedback

    /// A moment a widget button just logged, kept only long enough for the
    /// widget's own re-render to show it before the real server fetch
    /// (triggered right after) replaces it with the true tallies. Without
    /// this a tap gives no visible sign of having registered until the
    /// network round-trip completes — which, on a bad connection, can look
    /// exactly like a button that does nothing.
    public var pendingWidgetLog: PendingWidgetLog? {
        get {
            guard let data = defaults?.data(forKey: Key.pendingWidgetLog) else { return nil }
            return try? JSONDecoder().decode(PendingWidgetLog.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults?.removeObject(forKey: Key.pendingWidgetLog)
                return
            }
            defaults?.set(data, forKey: Key.pendingWidgetLog)
        }
    }

    // MARK: Privacy consent

    /// What this installation has agreed to. See `PrivacyConsent` for why it is
    /// held per installation rather than per account.
    ///
    /// In the App Group container rather than the app's own defaults so that a
    /// future extension can ask the same question without inventing a second
    /// answer. Not auth material, so this does not conflict with the rule that
    /// tokens live only in the Keychain (Requirement 8.5).
    public var privacyConsent: PrivacyConsent {
        PrivacyConsent(
            acceptedVersion: defaults?.string(forKey: Key.privacyPolicyAcceptedVersion),
            acceptedAt: defaults?.object(forKey: Key.privacyPolicyAcceptedAt) as? Date
        )
    }

    /// Records agreement to a policy version. `date` is injected so the record
    /// is testable.
    public func recordPrivacyConsent(
        version: String = PrivacyConsent.currentVersion,
        at date: Date = Date()
    ) {
        defaults?.set(version, forKey: Key.privacyPolicyAcceptedVersion)
        defaults?.set(date, forKey: Key.privacyPolicyAcceptedAt)
    }

    /// Forgets the agreement, putting the gate back in front of the next
    /// launch. Nothing in the app calls this — it exists for tests and for a
    /// hand-run reset, because a consent record with no way to clear it is
    /// impossible to check.
    public func clearPrivacyConsent() {
        defaults?.removeObject(forKey: Key.privacyPolicyAcceptedVersion)
        defaults?.removeObject(forKey: Key.privacyPolicyAcceptedAt)
    }

    // MARK: Push

    /// Whether notification authorization has already been requested for this
    /// installation (Requirement 18.9). Not auth material, so storing it here
    /// does not conflict with Requirement 8.5.
    public var hasRequestedNotificationAuthorization: Bool {
        get { defaults?.bool(forKey: Key.notificationAuthorizationRequested) ?? false }
        set { defaults?.set(newValue, forKey: Key.notificationAuthorizationRequested) }
    }

    /// The APNs device token most recently registered, kept so the `devices`
    /// record can be deleted at sign-out (Requirement 18.5).
    public var devicePushToken: String? {
        get { defaults?.string(forKey: Key.devicePushToken) }
        set { set(newValue, forKey: Key.devicePushToken) }
    }

    // MARK: Helpers

    private func set(_ value: String?, forKey key: String) {
        guard let value else {
            defaults?.removeObject(forKey: key)
            return
        }
        defaults?.set(value, forKey: key)
    }
}
