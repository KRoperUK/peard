import AuthenticationServices
import CryptoKit
import Foundation
import PeardCore
import UIKit

/// Errors that reach the sign-in screen.
enum AuthError: LocalizedError, Equatable {
    /// The user dismissed the dialog: return to sign-in with no message
    /// (Requirement 6.7, 7.6).
    case cancelled
    case noIdentityToken
    case missingGoogleClientID
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .noIdentityToken: return "Apple returned no identity token"
        case .missingGoogleClientID: return PeardConfig.missingGoogleClientIDMessage
        case .message(let text): return text
        }
    }
}

/// Sign in with Apple and Sign in with Google (Requirement 6, 7).
@MainActor
final class AuthCoordinator {
    private let api: APIClient
    private let config: PeardConfig

    /// The in-flight web authorization session, so a `peard://auth/google`
    /// deep link can be delivered to it (Requirement 19.4).
    private static weak var pendingWebSession: ASWebAuthenticationSession?
    private static var pendingRedirectHandler: ((URL) -> Void)?

    init(api: APIClient, config: PeardConfig) {
        self.api = api
        self.config = config
    }

    // MARK: Apple

    func signInWithApple() async throws -> Session {
        let rawNonce = Self.randomNonce()
        let credential: ASAuthorizationAppleIDCredential
        do {
            credential = try await AppleSignInController.shared.requestCredential(
                hashedNonce: Self.sha256Hex(rawNonce)
            )
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw AuthError.cancelled
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.message(error.localizedDescription)
        }

        guard
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8),
            !identityToken.isEmpty
        else {
            throw AuthError.noIdentityToken
        }

        // Apple sends the name only on the first authorization
        // (Requirement 6.4).
        let displayName = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        do {
            let response: AuthResponse = try await api.post(
                path: "/api/peard/auth/apple",
                fields: [
                    "identity_token": identityToken,
                    "nonce": rawNonce,
                    "display_name": displayName,
                ]
            )
            return Session(token: response.token, user: response.record)
        } catch let error as APIError {
            throw AuthError.message(error.localizedDescription)
        }
    }

    // MARK: Google

    func signInWithGoogle(presentationAnchor: ASPresentationAnchor?) async throws -> Session {
        guard config.hasGoogleClientID else { throw AuthError.missingGoogleClientID }

        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let redirectURI = "\(DeepLink.scheme)://auth/google"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else {
            throw AuthError.message("Couldn't build the Google sign-in URL.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await WebAuthorization.start(
                url: authorizationURL,
                callbackScheme: DeepLink.scheme,
                anchor: presentationAnchor
            )
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.cancelled
        }

        guard
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
            let code = items.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else {
            // Google reported an error, or the callback carried no code.
            throw AuthError.cancelled
        }

        do {
            let response: AuthResponse = try await api.post(
                path: "/api/collections/users/auth-with-oauth2",
                fields: [
                    "provider": "google",
                    "code": code,
                    "codeVerifier": verifier,
                    "redirectURL": redirectURI,
                ]
            )
            return Session(token: response.token, user: response.record)
        } catch let error as APIError {
            // Requirement 7.7 shows the server message; a transport failure is
            // a silent return to sign-in (clarification Q9).
            if error.serverMessage != nil {
                throw AuthError.message(error.localizedDescription)
            }
            if case .server = error {
                throw AuthError.message(error.localizedDescription)
            }
            throw AuthError.cancelled
        }
    }

    // MARK: Email

    func signInWithPassword(identity: String, password: String) async throws -> Session {
        do {
            let response: AuthResponse = try await api.post(
                path: "/api/collections/users/auth-with-password",
                fields: ["identity": identity, "password": password]
            )
            return Session(token: response.token, user: response.record)
        } catch let error as APIError {
            throw AuthError.message(AuthMessage.forSignIn(error))
        }
    }

    /// Creates an account, then signs into it.
    ///
    /// The sign-in screen offered an email and a password field and a Continue
    /// button that could only ever *authenticate*. There was no way to create an
    /// account with them, so a new user typing their details got "Failed to
    /// authenticate" and no route forward — a whole advertised sign-in method
    /// that only worked for accounts which could not be made in the app.
    ///
    /// `users` already permits public creation (its CreateRule is empty) and
    /// requires no verification to authenticate (its AuthRule is empty), so the
    /// two calls below are all it takes. The immediate sign-in matters: creating
    /// a record returns no token, and leaving somebody at the sign-in screen
    /// after they just made an account is a dead end that reads like a failure.
    ///
    /// `passwordConfirm` is sent because PocketBase requires it on create; the
    /// screen collects it once and passes it twice rather than asking the user
    /// to type their password out again, which is a checkbox for form design
    /// rather than for security on a field they can reveal.
    func signUpWithPassword(email: String, password: String) async throws -> Session {
        do {
            let _: UserRecord = try await api.create("users", fields: [
                "email": email,
                "password": password,
                "passwordConfirm": password,
                // Without this the address is private even to its owner, and
                // `GET /api/peard/profile` returns an empty email — so Settings
                // would say "Signed in as ." to somebody who had just typed it.
                "emailVisibility": "true",
            ])
        } catch let error as APIError {
            throw AuthError.message(AuthMessage.forSignUp(error))
        }
        return try await signInWithPassword(identity: email, password: password)
    }

    /// Delivers a `peard://auth/google` URL to the pending session
    /// (Requirement 19.4). `ASWebAuthenticationSession` normally consumes the
    /// callback itself, so this is a no-op safety net.
    static func deliverPendingAuthorization(url: URL) {
        pendingRedirectHandler?(url)
    }

    static func registerPending(session: ASWebAuthenticationSession?, handler: ((URL) -> Void)?) {
        pendingWebSession = session
        pendingRedirectHandler = handler
    }

    // MARK: Crypto helpers

    /// Requirement 6.2 — a fresh raw nonce per attempt.
    static func randomNonce(byteCount: Int = 32) -> String {
        randomBytes(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    /// Lower-case hexadecimal SHA-256, the form the server expects to match
    /// against Apple's echoed `nonce` claim.
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Requirement 7.2 — PKCE verifier and S256 challenge.
    static func randomCodeVerifier(byteCount: Int = 32) -> String {
        base64URL(Data(randomBytes(byteCount)))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return bytes
    }
}

// MARK: - Apple credential bridge

/// Bridges `ASAuthorizationController`'s delegate callbacks to `async`.
@MainActor
private final class AppleSignInController: NSObject, ASAuthorizationControllerDelegate,
                                           ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignInController()

    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func requestCredential(hashedNonce: String) async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AuthError.noIdentityToken)
            continuation = nil
            return
        }
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        PresentationAnchor.current() ?? ASPresentationAnchor()
    }
}

// MARK: - Web authorization bridge

@MainActor
private final class WebAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var retained: WebAuthorization?

    private var anchor: ASPresentationAnchor?

    static func start(url: URL, callbackScheme: String, anchor: ASPresentationAnchor?) async throws -> URL {
        let helper = WebAuthorization()
        helper.anchor = anchor
        retained = helper
        defer { retained = nil }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                guard !didResume else { return }
                didResume = true
                AuthCoordinator.registerPending(session: nil, handler: nil)

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                    return
                }
                continuation.resume(throwing: AuthError.cancelled)
            }
            session.presentationContextProvider = helper
            session.prefersEphemeralWebBrowserSession = false

            AuthCoordinator.registerPending(session: session) { callbackURL in
                guard !didResume else { return }
                didResume = true
                session.cancel()
                continuation.resume(returning: callbackURL)
            }
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? PresentationAnchor.current() ?? ASPresentationAnchor()
    }
}

/// Finds the active window to anchor system dialogs to.
enum PresentationAnchor {
    @MainActor
    static func current() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
