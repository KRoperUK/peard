import Foundation

/// Whether this installation has agreed to the privacy policy, and to which
/// version of it.
///
/// This is a precondition for the app doing anything over the network at all,
/// not a checkbox on the sign-in form. Signing in with Apple, Google or an
/// email address all send an identifier off the device before there is any
/// account to speak of — so consent has to be a gate in front of the sign-in
/// screen rather than something collected alongside it.
///
/// Stored per installation rather than per account, because it is the person
/// holding the device who agrees, and because there is no account yet at the
/// point the question is asked. It deliberately survives sign-out: signing out
/// and back in is not a new relationship, and re-asking would train people to
/// dismiss the screen without reading it.
public struct PrivacyConsent: Sendable, Equatable {
    /// Bumped when the policy changes in a way people ought to see. A version
    /// they have not accepted puts the gate back in front of them — which is
    /// the point of storing the version rather than a bare boolean.
    ///
    /// Matches the "Last updated" date rendered by the server's `/privacy`
    /// page (`server/internal/site/site.go`); keep the two in step.
    public static let currentVersion = "2026-07-31"

    /// The policy version this installation accepted, or nil on first run.
    public let acceptedVersion: String?
    /// When it was accepted. Kept so the acceptance can be evidenced later —
    /// "they agreed" is a claim, "they agreed to version X on date Y" is a
    /// record.
    public let acceptedAt: Date?

    public init(acceptedVersion: String? = nil, acceptedAt: Date? = nil) {
        self.acceptedVersion = acceptedVersion
        self.acceptedAt = acceptedAt
    }

    /// The only question callers should ask. An older accepted version counts
    /// as no consent for the current one.
    public var hasAcceptedCurrentVersion: Bool {
        acceptedVersion == Self.currentVersion
    }

    /// True when nothing has ever been accepted, which is what distinguishes a
    /// first run from a policy update — the two want different wording.
    public var isFirstRun: Bool { acceptedVersion == nil }
}
