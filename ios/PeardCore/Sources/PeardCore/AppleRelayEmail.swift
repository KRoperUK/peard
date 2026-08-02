import Foundation

/// Sign in with Apple's "Hide My Email" addresses.
///
/// Apple issues one per app, per account — `something@privaterelay.appleid.com`
/// — and forwards mail to the real address without ever revealing it. That is
/// the point of the feature and it works well, but it means the address has
/// never been anybody's address: it cannot be in a contact card, so hashing it
/// for contact matching produces a value nothing can ever match.
///
/// Detected on the client as well as the server so the app can explain the
/// problem where somebody meets it — the Settings screen, next to the toggle
/// that is not working for them — rather than leaving them to conclude the
/// feature is broken.
public enum AppleRelayEmail {
    public static let domain = "@privaterelay.appleid.com"

    public static func isRelay(_ email: String?) -> Bool {
        guard let email else { return false }
        return email.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(domain)
    }
}
