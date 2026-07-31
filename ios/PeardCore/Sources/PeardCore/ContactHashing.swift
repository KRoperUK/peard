import CryptoKit
import Foundation

/// Mirrors `server/internal/contacts`' hashing exactly — same
/// normalisation, same SHA-256, same "email:"/"phone:" namespace prefix — so
/// a contact hashed on this device matches the hash the server already
/// stores for an account with that email or phone. See that package's doc
/// comment for the privacy trade-off (unsalted SHA-256 is reversible by
/// brute force for a small input space like a phone number) and for why
/// phone matching has no country-code inference: a contact saved locally
/// without its country code simply will not match.
public enum ContactHashing {
    public static func normaliseEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// ASCII digits only, matching Go's `r >= '0' && r <= '9'` exactly —
    /// `Character.isNumber` is deliberately not used here, since it also
    /// admits non-ASCII numerals Go's byte-range check would not.
    public static func normalisePhone(_ phone: String) -> String {
        var digits = String.UnicodeScalarView()
        for scalar in phone.unicodeScalars where scalar.value >= 48 && scalar.value <= 57 {
            digits.append(scalar)
        }
        return String(digits)
    }

    public static func hashEmail(_ email: String) -> String? {
        let normalised = normaliseEmail(email)
        guard !normalised.isEmpty else { return nil }
        return hash("email:" + normalised)
    }

    public static func hashPhone(_ phone: String) -> String? {
        let normalised = normalisePhone(phone)
        guard !normalised.isEmpty else { return nil }
        return hash("phone:" + normalised)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
