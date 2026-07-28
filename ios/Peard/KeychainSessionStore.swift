import Foundation
import PeardCore
import Security

/// An established PocketBase session.
struct Session: Equatable, Sendable {
    let token: String
    let user: UserRecord

    var userID: String { user.id }
}

/// Persists the auth token and user id in the Keychain (Requirement 8).
///
/// Nothing auth-related is written to `UserDefaults.standard` (Requirement 8.5);
/// `clear()` additionally removes keys that earlier React Native builds left in
/// `UserDefaults` and `AsyncStorage`'s backing store.
final class KeychainSessionStore: AuthTokenProviding, @unchecked Sendable {
    private enum Account {
        static let token = "authToken"
        static let userID = "userID"
    }

    static let service = "com.peard.app.session"

    /// Keys the Expo build may have written; removed on load and on sign-out.
    private static let legacyUserDefaultsKeys = ["peard_token", "peard_uid", "pb_auth"]

    private let service: String
    private let lock = NSLock()
    private var cachedToken: String?
    private var cachedUserID: String?
    private var didLoad = false

    init(service: String = KeychainSessionStore.service) {
        self.service = service
    }

    // MARK: AuthTokenProviding

    var authToken: String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return cachedToken
    }

    var userID: String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return cachedUserID
    }

    var hasSession: Bool {
        guard let authToken, !authToken.isEmpty, let userID, !userID.isEmpty else { return false }
        return true
    }

    // MARK: Mutation

    /// Persists a session with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// (Requirement 8.1). Throws when the Keychain refuses the write, so the
    /// caller can report a failed session establishment.
    func save(token: String, userID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(token, account: Account.token)
        try write(userID, account: Account.userID)
        cachedToken = token
        cachedUserID = userID
        didLoad = true
    }

    /// Removes the persisted session (Requirement 8.3) and any legacy copies.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        delete(account: Account.token)
        delete(account: Account.userID)
        cachedToken = nil
        cachedUserID = nil
        didLoad = true
        Self.removeLegacyUserDefaults()
    }

    /// Loads the persisted session (Requirement 8.2).
    func load() {
        lock.lock()
        defer { lock.unlock() }
        didLoad = false
        loadIfNeededLocked()
    }

    // MARK: Keychain plumbing

    private func loadIfNeededLocked() {
        guard !didLoad else { return }
        didLoad = true
        cachedToken = read(account: Account.token)
        cachedUserID = read(account: Account.userID)
        Self.removeLegacyUserDefaults()
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func write(_ value: String, account: String) throws {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionStoreError.keychain(status)
        }
    }

    private func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else { return nil }
        return value
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func removeLegacyUserDefaults() {
        let defaults = UserDefaults.standard
        for key in legacyUserDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}

enum SessionStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't save your session to the Keychain (\(detail))."
        }
    }
}
