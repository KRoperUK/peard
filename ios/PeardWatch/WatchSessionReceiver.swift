import Foundation
import PeardCore
import WatchConnectivity
import WidgetKit

/// Receives the widget credentials from the phone (issue #8) and keeps them in
/// the App Group, where the complications read them too.
final class WatchSessionReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Called on the main actor whenever the credentials change.
    var onChange: (@MainActor () -> Void)?

    private let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// With nothing stored, asks the phone for what it has. The answer only
    /// comes while the phone is reachable; otherwise the application context
    /// arrives on its own once it is.
    func requestIfMissing() {
        guard WatchCredentials(store: store) == nil else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["request": "credentials"], replyHandler: { [weak self] reply in
            self?.apply(reply)
        }, errorHandler: nil)
    }

    private func apply(_ context: [String: Any]) {
        WatchCredentials.apply(context, to: store)
        WidgetCenter.shared.reloadAllTimelines()
        Task { @MainActor [onChange] in onChange?() }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        // The latest context the phone sent, possibly while this app was not
        // running.
        if !session.receivedApplicationContext.isEmpty {
            apply(session.receivedApplicationContext)
        }
        requestIfMissing()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        requestIfMissing()
    }
}
