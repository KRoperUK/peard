import Foundation

/// A thread-safe, settable auth token holder, for clients whose token is
/// obtained after the client is constructed.
public final class TokenBox: AuthTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public var authToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func set(_ token: String?) {
        lock.lock()
        self.token = token
        lock.unlock()
    }
}
