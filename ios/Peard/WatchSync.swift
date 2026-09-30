import Foundation
import PeardCore
import WatchConnectivity

/// Hands the watch the widget credentials (issue #8).
///
/// Everything that writes or clears them goes through `WidgetSync`, which
/// calls `update(_:)`, so the watch follows sign-in and sign-out without any
/// other part of the app knowing it exists. The credentials travel as
/// application context: WatchConnectivity keeps the latest and delivers it
/// whenever the watch is next reachable.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private let lock = NSLock()
    private var pending: [String: Any]?

    func update(_ credentials: WatchCredentials?) {
        guard WCSession.isSupported() else { return }
        let context = credentials?.applicationContext ?? WatchCredentials.signedOutContext
        let session = WCSession.default
        if session.activationState == .activated {
            send(context, on: session)
            return
        }
        lock.withLock { pending = context }
        activate(session)
    }

    /// Activated at launch too, so a watch asking for credentials is answered
    /// even before this launch has synced any.
    func activate(_ session: WCSession = .default) {
        guard WCSession.isSupported() else { return }
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated { session.activate() }
    }

    private func send(_ context: [String: Any], on session: WCSession) {
        // Nothing to send to without a watch running the app; `sessionWatchStateDidChange`
        // catches the app being installed later.
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(context)
    }

    private static var current: [String: Any] {
        WatchCredentials(store: .shared)?.applicationContext ?? WatchCredentials.signedOutContext
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        let context = lock.withLock { () -> [String: Any]? in
            defer { pending = nil }
            return pending
        }
        send(context ?? Self.current, on: session)
    }

    /// The watch app was installed, or the watch changed, after sign-in.
    func sessionWatchStateDidChange(_ session: WCSession) {
        send(Self.current, on: session)
    }

    /// A watch that has no credentials asks for them when it opens, which
    /// covers the app being installed while the phone was not running.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler(Self.current)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another paired watch deactivates the session; activating
    /// again is how it moves to the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
