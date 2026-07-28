#if DEBUG
import Foundation
import OSLog
import PeardCore

/// Debug-only shortcuts (Requirement 21). The whole file is compiled out of
/// Release builds, so neither the controls nor the code paths ship
/// (Requirement 21.4, clarification Q20).
enum DebugSupport {
    static let logger = Logger(subsystem: "com.peard.app", category: "debug")

    static let testEmail = "test@peard.local"
    static let testPassword = "test1234"
    static let partnerEmail = "partner@peard.local"
    static let fakePairCode = "AAAAAA"

    /// Superuser credentials used only by `createFakePair`, overridable from
    /// the build configuration.
    static var superuserIdentity: String {
        value(for: "PeardDebugSuperuserIdentity") ?? "admin@peard.app"
    }

    static var superuserPassword: String {
        value(for: "PeardDebugSuperuserPassword") ?? "Password123!"
    }

    private static func value(for key: String) -> String? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !raw.isEmpty,
            !raw.contains("$(")
        else { return nil }
        return raw
    }

    /// Requirement 21.5 — log the reachability of `GET /api/health` at launch.
    static func logHealth(api: APIClient) async {
        do {
            let code = try await api.healthCode()
            logger.info("server reachable at \(api.baseURL.absoluteString, privacy: .public): \(code)")
        } catch {
            logger.warning("server unreachable at \(api.baseURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Requirement 21.1 — password sign-in as the fixed test account.
    static func signInAsTestUser(api: APIClient) async throws -> Session {
        let response: AuthResponse = try await api.post(
            path: "/api/collections/users/auth-with-password",
            fields: ["identity": testEmail, "password": testPassword]
        )
        return Session(token: response.token, user: response.record)
    }

    /// Requirement 21.3 — build a pair with a seeded partner and two seeded
    /// event posts. `pairs`, `pair_members` and `users` creation are closed to
    /// ordinary users, so this authenticates a superuser first.
    @MainActor
    static func createFakePair(app: AppModel) async throws {
        let userID = app.signedInUserID
        guard !userID.isEmpty else { throw APIError.unauthorized(message: "Sign in first.") }

        let superuser = SuperuserClient(baseURL: app.config.serverURL)
        try await superuser.authenticate(
            identity: superuserIdentity,
            password: superuserPassword
        )

        let pairID = try await superuser.createPair()
        let partnerID = try await superuser.findOrCreatePartner(
            email: partnerEmail,
            password: testPassword,
            displayName: "Test Partner"
        )

        try await superuser.addMember(pairID: pairID, userID: userID, role: "owner")
        try await superuser.addMember(pairID: pairID, userID: partnerID, role: "member")

        try await superuser.seedEvent(pairID: pairID, authorID: partnerID, kind: "beer", note: "Welcome to Pear'd! 🍐")
        try await superuser.seedEvent(pairID: pairID, authorID: partnerID, kind: "coffee", note: "Good morning!")
    }
}

/// A separate client holding the superuser token, so the user's own session in
/// the Keychain is never touched.
private final class SuperuserClient {
    private struct Identified: Codable, Hashable, Sendable { let id: String }

    private let tokenBox = TokenBox()
    /// Unauthenticated client used for the superuser password exchange.
    private let api: APIClient
    /// Client that sends the superuser token.
    private let authenticatedAPI: APIClient

    init(baseURL: URL) {
        self.api = APIClient(baseURL: baseURL)
        self.authenticatedAPI = APIClient(baseURL: baseURL, tokenProvider: tokenBox)
    }

    func authenticate(identity: String, password: String) async throws {
        let response: AuthResponse = try await api.post(
            path: "/api/collections/_superusers/auth-with-password",
            fields: ["identity": identity, "password": password]
        )
        tokenBox.set(response.token)
    }

    func createPair() async throws -> String {
        let pair: Identified = try await authenticatedAPI.create("pairs", fields: [:])
        return pair.id
    }

    func findOrCreatePartner(email: String, password: String, displayName: String) async throws -> String {
        if let existing: Identified = try await authenticatedAPI.first(
            "users",
            of: Identified.self,
            filter: PeardFilter.equals("email", email)
        ) {
            return existing.id
        }
        let created: Identified = try await authenticatedAPI.create("users", fields: [
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "display_name": displayName,
            "verified": "true",
        ])
        return created.id
    }

    func addMember(pairID: String, userID: String, role: String) async throws {
        let _: Identified = try await authenticatedAPI.create("pair_members", fields: [
            "pair": pairID,
            "user": userID,
            "role": role,
        ])
    }

    func seedEvent(pairID: String, authorID: String, kind: String, note: String) async throws {
        let _: Identified = try await authenticatedAPI.create("posts", fields: [
            "pair": pairID,
            "author": authorID,
            "type": "event",
            "event_kind": kind,
            "note": note,
        ])
    }
}
#endif
