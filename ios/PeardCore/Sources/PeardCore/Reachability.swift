import Foundation
import Network

/// Watches whether the device has a usable network path.
///
/// Exists so the send queue can flush the moment connectivity returns rather than
/// waiting for the user to reopen the app and tap something. `NWPathMonitor` is
/// the right primitive: it reports the *path*, so it also catches the captive
/// portal and the "connected to Wi-Fi with no route" cases that a reachability
/// ping would call online.
///
/// Deliberately not an `actor`: `NWPathMonitor` delivers on a queue of its own
/// choosing and the only shared state is one `Bool`, so a lock is both cheaper and
/// easier to reason about than hopping executors on every path update.
public final class Reachability: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.peard.reachability")
    private let lock = NSLock()

    private var _isOnline = true
    private var handlers: [@Sendable (Bool) -> Void] = []
    private var isStarted = false

    public init() {
        monitor = NWPathMonitor()
    }

    /// True when a network path is available. Optimistic before the first update
    /// arrives: assuming offline would make the first tap of a launch queue
    /// itself needlessly.
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    /// Begins monitoring. Safe to call more than once.
    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isOnline: path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let wasStarted = isStarted
        isStarted = false
        lock.unlock()
        if wasStarted { monitor.cancel() }
    }

    /// Registers a handler called on every change, and only on a change — a
    /// path update that reports the same status as last time is not worth a flush.
    public func onChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    private func update(isOnline: Bool) {
        lock.lock()
        guard isOnline != _isOnline else {
            lock.unlock()
            return
        }
        _isOnline = isOnline
        let toNotify = handlers
        lock.unlock()

        for handler in toNotify {
            handler(isOnline)
        }
    }
}
