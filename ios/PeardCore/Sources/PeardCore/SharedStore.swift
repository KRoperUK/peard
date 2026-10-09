import Foundation

/// Read/write access to the App Group container shared by the app and the
/// widget, replacing the `PearShared` Expo native module (Requirement 16.5).
///
/// Keys match the ones the React Native build wrote, so an already-installed
/// widget keeps working after the migration.
public final class SharedStore: @unchecked Sendable {
    public enum Key {
        public static let widgetToken = "widgetToken"
        public static let widgetTokenID = "widgetTokenId"
        public static let apiBaseURL = "apiBaseUrl"
        public static let notificationAuthorizationRequested = "notificationAuthorizationRequested"
        public static let devicePushToken = "devicePushToken"
        public static let selectedConnectionID = "selectedConnectionId"
        public static let messagesConnectionID = "messagesConnectionId"
        public static let pendingWidgetLog = "pendingWidgetLog"
        public static let privacyPolicyAcceptedVersion = "privacyPolicyAcceptedVersion"
        public static let privacyPolicyAcceptedAt = "privacyPolicyAcceptedAt"
        public static let appearance = "appearance"
        public static let pinnedMoments = "pinnedMoments"
        public static let waterConfigs = "waterConfigs"
        public static let waterUnit = "waterUnit"
        public static let watchLastMoments = "watchLastMoments"
        public static let cachedMoments = "cachedMoments"
        public static let cachedAvatars = "cachedAvatars"
        /// Read by the notification service extension too, which has no
        /// PeardCore and so spells it out itself; NotificationServiceTests
        /// keeps the two in step.
        public static let lowData = "lowData"
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

    /// The server's record id for `widgetToken`. Not a credential — it is what the
    /// devices screen compares against to mark this device's own row (#367).
    public var widgetTokenID: String? {
        get { defaults?.string(forKey: Key.widgetTokenID) }
        set { set(newValue, forKey: Key.widgetTokenID) }
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
        defaults?.removeObject(forKey: Key.widgetTokenID)
    }

    // MARK: Connections

    /// The connection the home screen last showed, so a user in several lands
    /// back where they left off. Not auth material.
    public var selectedConnectionID: String? {
        get { defaults?.string(forKey: Key.selectedConnectionID) }
        set { set(newValue, forKey: Key.selectedConnectionID) }
    }

    /// The connection the Messages tray last logged into.
    ///
    /// Kept apart from `selectedConnectionID` on purpose. Which connection you
    /// log into from a chat is not the same question as which one the app
    /// should open on, and writing the app's answer from inside an extension
    /// would move the home screen under somebody who never asked for that.
    public var messagesConnectionID: String? {
        get { defaults?.string(forKey: Key.messagesConnectionID) }
        set { set(newValue, forKey: Key.messagesConnectionID) }
    }

    // MARK: Appearance

    /// Whether the app follows the system's light/dark setting or is pinned.
    ///
    /// In the App Group rather than the app's own defaults so it sits with the
    /// rest of the shared state. The extensions do not act on it — WidgetKit
    /// renders a widget in the system's appearance whatever its host app
    /// prefers, and that is Apple's call rather than something to work around —
    /// but a second home for one setting is a second thing to keep in step.
    public var appearance: AppearancePreference {
        get { AppearancePreference(storedValue: defaults?.string(forKey: Key.appearance)) }
        set { set(newValue.rawValue, forKey: Key.appearance) }
    }

    // MARK: Low data

    /// Whether to hold back on data; see `LowDataPreference`.
    ///
    /// In the App Group because, unlike appearance, the extensions do act on
    /// this one: the notification service skips the photo download, and the
    /// widget asks for its smaller photo.
    public var lowData: LowDataPreference {
        get { LowDataPreference(storedValue: defaults?.string(forKey: Key.lowData)) }
        set { set(newValue.rawValue, forKey: Key.lowData) }
    }

    // MARK: Water unit

    /// Millilitres or fluid ounces, for display only (#324); see `WaterUnit`.
    ///
    /// The user's, so one value for every connection, unlike `WaterConfig`.
    /// Nothing stored until somebody chooses: the locale decides until then. What
    /// a moment carries is millilitres either way, so this never touches data.
    public var waterUnit: WaterUnit {
        get { waterUnit(locale: .current) }
        set { set(newValue.rawValue, forKey: Key.waterUnit) }
    }

    /// The same, against a given locale; the testable form of the getter.
    public func waterUnit(locale: Locale) -> WaterUnit {
        WaterUnit(storedValue: defaults?.string(forKey: Key.waterUnit), locale: locale)
    }

    // MARK: Pinned moments

    /// The moment slugs pinned to the front of a connection's grid, in pin
    /// order. See `MomentPins`.
    public func pinnedMoments(forConnection pairID: String) -> [String] {
        let all = defaults?.dictionary(forKey: Key.pinnedMoments) as? [String: [String]]
        return all?[pairID] ?? []
    }

    public func setPinnedMoments(_ slugs: [String], forConnection pairID: String) {
        var all = (defaults?.dictionary(forKey: Key.pinnedMoments) as? [String: [String]]) ?? [:]
        all[pairID] = slugs.isEmpty ? nil : slugs
        defaults?.set(all, forKey: Key.pinnedMoments)
    }

    // MARK: Water settings

    /// A connection's water settings (#322): targets, chip sizes, on or off.
    ///
    /// Client-local and per connection, keyed like pins: nothing on the server
    /// changes. Should gamification (#323) need targets both people see, that
    /// will want a server-shared copy; this is deliberately only this device's
    /// choice until then. A connection that has set nothing, or whose record
    /// cannot be read, has `WaterConfig.standard` — never a crash.
    public func waterConfig(forConnection pairID: String) -> WaterConfig {
        guard
            let all = defaults?.dictionary(forKey: Key.waterConfigs) as? [String: Data],
            let data = all[pairID],
            let config = try? JSONDecoder().decode(WaterConfig.self, from: data)
        else { return .standard }
        return config
    }

    public func setWaterConfig(_ config: WaterConfig, forConnection pairID: String) {
        var all = (defaults?.dictionary(forKey: Key.waterConfigs) as? [String: Data]) ?? [:]
        // The standard settings are stored as nothing, so resetting forgets
        // rather than remembers — and a later change to the built-in defaults
        // reaches a connection that never customised them.
        all[pairID] = config == .standard ? nil : try? JSONEncoder().encode(config)
        defaults?.set(all, forKey: Key.waterConfigs)
    }

    // MARK: Cached moment definitions

    /// The connection's custom moments as last fetched, kept so the Home grid
    /// still offers them with no signal (#313). Per connection, like pins: a
    /// group's moments are not a pair's.
    public func cachedMomentKinds(forConnection pairID: String) -> [MomentKind] {
        guard
            let all = defaults?.dictionary(forKey: Key.cachedMoments) as? [String: Data],
            let data = all[pairID],
            let kinds = try? JSONDecoder.peard.decode([MomentKind].self, from: data)
        else { return [] }
        return kinds
    }

    public func setCachedMomentKinds(_ kinds: [MomentKind], forConnection pairID: String) {
        var all = (defaults?.dictionary(forKey: Key.cachedMoments) as? [String: Data]) ?? [:]
        // An empty list forgets rather than remembers: a connection whose custom
        // moments were all removed should not keep offering them offline.
        if kinds.isEmpty {
            all[pairID] = nil
        } else {
            all[pairID] = try? JSONEncoder.peard.encode(kinds)
        }
        defaults?.set(all, forKey: Key.cachedMoments)
    }

    // MARK: Cached avatars

    /// The bytes of an avatar as last downloaded, kept so a face still draws
    /// with no signal (#313). Keyed by owner and record id rather than filename
    /// (see `AvatarView`), so a replaced photo overwrites the old one instead of
    /// accumulating; the thumb size is part of the key because the rail and the
    /// settings circle ask for different ones.
    public func cachedAvatar(forKey key: String) -> Data? {
        (defaults?.dictionary(forKey: Key.cachedAvatars) as? [String: Data])?[key]
    }

    public func setCachedAvatar(_ data: Data?, forKey key: String) {
        var all = (defaults?.dictionary(forKey: Key.cachedAvatars) as? [String: Data]) ?? [:]
        all[key] = data
        defaults?.set(all, forKey: Key.cachedAvatars)
    }

    // MARK: Watch

    /// The slug of the moment last logged from the watch to a connection, for
    /// its log-again tile (issue #287). Per connection, like pins: a group's
    /// moments are not a pair's, and the last coffee logged to one says nothing
    /// about what comes next in the other. The watch has its own App Group
    /// container, so the phone never sees this.
    public func lastWatchMoment(forConnection pairID: String) -> String? {
        let all = defaults?.dictionary(forKey: Key.watchLastMoments) as? [String: String]
        return all?[pairID]
    }

    public func setLastWatchMoment(_ slug: String, forConnection pairID: String) {
        var all = (defaults?.dictionary(forKey: Key.watchLastMoments) as? [String: String]) ?? [:]
        all[pairID] = slug
        defaults?.set(all, forKey: Key.watchLastMoments)
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
