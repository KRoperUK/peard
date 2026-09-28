import XCTest
@testable import PeardCore

/// The server can only revoke Sign in with Apple on account deletion if it was
/// given the authorization code at sign-in, so the code has to be in the body.
final class AppleSignInRequestTests: XCTestCase {
    func testCarriesTheAuthorizationCode() {
        let fields = AppleSignInRequest.fields(
            identityToken: "id-token",
            authorizationCode: Data("one-time-code".utf8),
            nonce: "raw-nonce",
            displayName: "Ada Lovelace"
        )
        XCTAssertEqual(fields, [
            "identity_token": "id-token",
            "authorization_code": "one-time-code",
            "nonce": "raw-nonce",
            "display_name": "Ada Lovelace",
        ])
    }

    func testLeavesOutAMissingOrEmptyCode() {
        for code in [nil, Data()] {
            let fields = AppleSignInRequest.fields(
                identityToken: "id-token",
                authorizationCode: code,
                nonce: "raw-nonce",
                displayName: ""
            )
            XCTAssertNil(fields["authorization_code"])
            XCTAssertEqual(fields["identity_token"], "id-token")
        }
    }
}
