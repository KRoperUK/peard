import Foundation

/// What the phone hands the watch so it can log moments (issue #8).
///
/// The widget token, not the session: it can read the feed and the
/// connections and log a moment, which is everything the watch does, and it
/// can be revoked on its own. The session never leaves the phone.
///
/// Sent as WatchConnectivity application context, which is a property-list
/// dictionary that the system delivers once the watch is reachable and keeps
/// only the latest of — exactly right for "the current credentials", including
/// "there are none any more".
public struct WatchCredentials: Equatable, Sendable {
    public let token: String
    public let baseURL: URL

    public init(token: String, baseURL: URL) {
        self.token = token
        self.baseURL = baseURL
    }

    /// The credentials the phone currently holds for its widgets, or `nil`
    /// when signed out.
    public init?(store: SharedStore) {
        guard let token = store.widgetToken, !token.isEmpty, let baseURL = store.apiBaseURL else { return nil }
        self.init(token: token, baseURL: baseURL)
    }

    public init?(applicationContext: [String: Any]) {
        guard
            let token = applicationContext[SharedStore.Key.widgetToken] as? String, !token.isEmpty,
            let raw = applicationContext[SharedStore.Key.apiBaseURL] as? String,
            let baseURL = URL(string: raw)
        else { return nil }
        self.init(token: token, baseURL: baseURL)
    }

    public var applicationContext: [String: Any] {
        [SharedStore.Key.widgetToken: token, SharedStore.Key.apiBaseURL: baseURL.absoluteString]
    }

    /// The context that tells the watch the phone signed out. An empty token
    /// rather than an empty dictionary, because WatchConnectivity does not
    /// deliver a context identical to the last one it sent.
    public static let signedOutContext: [String: Any] = [SharedStore.Key.widgetToken: ""]

    /// Stores what the phone sent, or forgets the token when it says it
    /// signed out. Returns whether the watch now has credentials.
    @discardableResult
    public static func apply(_ applicationContext: [String: Any], to store: SharedStore) -> Bool {
        if let credentials = WatchCredentials(applicationContext: applicationContext) {
            store.writeWidgetCredentials(token: credentials.token, baseURL: credentials.baseURL)
            return true
        }
        store.removeWidgetToken()
        return false
    }
}
