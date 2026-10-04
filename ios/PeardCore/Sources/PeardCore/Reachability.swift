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
    private var _isConstrained = false
    private var handlers: [@Sendable (Bool) -> Void] = []
    private var constrainedHandlers: [@Sendable (Bool) -> Void] = []
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

    /// True when iOS Low Data Mode is on for the current network — what the
    /// system calls a constrained path. False until the first update says
    /// otherwise, so a launch never starts out in low-data behaviour it does
    /// not need.
    public var isConstrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConstrained
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
            self?.update(isConstrained: path.isConstrained)
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

    /// Like `onChange`, for Low Data Mode being switched on or off — or for
    /// moving between networks that differ in it.
    public func onConstrainedChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        constrainedHandlers.append(handler)
        lock.unlock()
    }

    private func update(isConstrained: Bool) {
        lock.lock()
        guard isConstrained != _isConstrained else {
            lock.unlock()
            return
        }
        _isConstrained = isConstrained
        let toNotify = constrainedHandlers
        lock.unlock()

        for handler in toNotify {
            handler(isConstrained)
        }
    }

    /// One reading of whether the current path is constrained, for code that
    /// runs briefly and cannot keep a monitor — the widget's timeline provider.
    ///
    /// `NWPathMonitor` has no synchronous answer: its `currentPath` is empty
    /// until the first update arrives on the queue. That update comes almost
    /// at once, but not always, so the wait is bounded and a timeout reads as
    /// unconstrained — the normal behaviour, rather than a guess at low data.
    public static func probeIsConstrained(timeout: TimeInterval = 1) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.peard.reachability.probe")
        let answer = ProbeAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            monitor.pathUpdateHandler = { path in
                answer.resume(path.isConstrained)
                monitor.cancel()
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                answer.resume(false)
                monitor.cancel()
            }
        }
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

/// Resumes the probe's continuation once, whichever of the path update and the
/// timeout gets there first. Both run on the probe's serial queue, but a class
/// with a lock says so without depending on it.
private final class ProbeAnswer: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Bool, Never>?

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
