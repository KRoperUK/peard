import Foundation
import PeardCore

/// Turns what the server says into something a person can act on.
///
/// PocketBase answers a wrong password with "Failed to authenticate." — accurate,
/// and useless: it does not distinguish an unknown address from a wrong password
/// from a server that is down, and it suggests nothing to do next. Adding sign-up
/// made that worse rather than better, because the likeliest error on a new
/// account — "that email is already registered" — is one the user resolves by
/// doing something else entirely, namely signing in.
///
/// Deliberately a small pure mapper rather than a nicer `errorDescription` on
/// `APIError`: the same status means different things on the two routes. A 400
/// from sign-in is a bad credential; a 400 from sign-up is usually an address
/// already taken. Only the caller knows which it asked for.
enum AuthMessage {
    /// Wording for a failed `auth-with-password`.
    static func forSignIn(_ error: APIError) -> String {
        switch error.status {
        case 400, 401, 403:
            // PocketBase does not distinguish "no such account" from "wrong
            // password", and neither should this: saying which one was wrong
            // tells anybody who asks whether an address has an account here.
            return "That email and password don't match an account. Check them, or create an account instead."
        case 429:
            return "Too many attempts. Wait a minute and try again."
        default:
            return fallback(error)
        }
    }

    /// Wording for a failed account creation.
    static func forSignUp(_ error: APIError) -> String {
        guard error.status == 400 else {
            return error.status == 429
                ? "Too many attempts. Wait a minute and try again."
                : fallback(error)
        }
        let detail = (error.serverMessage ?? "").lowercased()
        if detail.contains("email"), detail.contains("unique") || detail.contains("already") {
            return "There's already an account with that email. Sign in instead."
        }
        if detail.contains("password") {
            return "That password is too short — use at least 8 characters."
        }
        if detail.contains("email") {
            return "That doesn't look like an email address."
        }
        return "Those details weren't accepted. Check the email, and use a password of at least 8 characters."
    }

    /// Anything that is not the server rejecting the credentials is, from the
    /// user's side, "it didn't get there" — worth saying plainly, because that
    /// fix is theirs rather than ours.
    private static func fallback(_ error: APIError) -> String {
        if case .transport = error {
            return "Couldn't reach Pear'd. Check your connection and try again."
        }
        return error.localizedDescription
    }
}
