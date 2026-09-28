import Foundation

/// The body of `POST /api/peard/auth/apple`.
///
/// The authorization code rides along with the identity token so the server can
/// exchange it for a refresh token, which is what it later hands back to Apple
/// to revoke the app's access when the account is deleted (App Store guideline
/// 5.1.1(v)). The identity token alone cannot be revoked. The code is optional
/// on the server, so it is left out rather than sent empty when Apple supplies
/// none.
public enum AppleSignInRequest {
    public static func fields(
        identityToken: String,
        authorizationCode: Data?,
        nonce: String,
        displayName: String
    ) -> [String: String] {
        var fields = [
            "identity_token": identityToken,
            "nonce": nonce,
            "display_name": displayName,
        ]
        if let data = authorizationCode, let code = String(data: data, encoding: .utf8), !code.isEmpty {
            fields["authorization_code"] = code
        }
        return fields
    }
}
