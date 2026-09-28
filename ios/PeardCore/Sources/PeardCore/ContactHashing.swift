import CryptoKit
import Foundation

/// Mirrors `server/internal/contacts`' hashing exactly — same
/// normalisation, same SHA-256, same "email:"/"phone:" namespace prefix — so
/// a contact hashed on this device matches an account with that email or
/// phone. The server keys what it stores (HMAC under a server secret,
/// `PEARD_CONTACT_HASH_KEY`) and applies the same key to what this sends, so
/// this side stays plain SHA-256 and every installed build keeps working.
///
/// Be clear about what that buys. The key means a copy of the server's
/// database can no longer be reversed by brute force. It does not hide these
/// hashes from the server itself: they arrive unkeyed (over TLS), and a phone
/// number's SHA-256 is still reversible by trying every number, so whoever runs
/// the server could recover them. Closing that needs private set intersection,
/// which is out of scope. See that package's doc comment for more, and for why
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
