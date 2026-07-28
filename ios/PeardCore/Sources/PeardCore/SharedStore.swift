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
