import XCTest
@testable import Peard
import PeardCore

/// What the sign-in screen tells somebody when the server says no.
///
/// These strings are the entire recovery path for a failed sign-in — there is no
/// support channel in the app and the server sends no email — so "wrong" here
/// means somebody cannot get into their account.
final class AuthMessageTests: XCTestCase {
    // MARK: Sign in

    /// PocketBase cannot tell these apart and neither should the copy: naming
    /// which half was wrong tells anybody who asks whether an address has an
    /// account on this server.
    func testBadCredentialsDoNotRevealWhetherTheAccountExists() {
        let message = AuthMessage.forSignIn(.server(status: 400, message: "Failed to authenticate."))

        XCTAssertFalse(message.lowercased().contains("no account"))
        XCTAssertFalse(message.lowercased().contains("not found"))
        XCTAssertFalse(message.lowercased().contains("wrong password"))
        XCTAssertTrue(message.contains("don't match"))
    }

    /// The dead end this replaces: a new user typing their details got told to
    /// check them, with nothing suggesting the account had to be made first.
    func testSignInFailurePointsAtCreatingAnAccount() {
        let message = AuthMessage.forSignIn(.server(status: 400, message: "Failed to authenticate."))

        XCTAssertTrue(message.lowercased().contains("create an account"))
    }

    func testA401IsTreatedAsABadCredentialNotAnExpiredSession() {
        let message = AuthMessage.forSignIn(.unauthorized(message: "Failed to authenticate."))

        XCTAssertTrue(message.contains("don't match"))
    }

    func testRateLimitingSaysToWait() {
        XCTAssertTrue(AuthMessage.forSignIn(.server(status: 429, message: nil)).contains("Wait a minute"))
    }

    /// A request that never arrived is the user's network, not their password —
    /// telling them to check their credentials would send them to fix the wrong
    /// thing.
    func testATransportFailureBlamesTheConnection() {
        let message = AuthMessage.forSignIn(.transport("The Internet connection appears to be offline."))

        XCTAssertTrue(message.contains("Check your connection"))
        XCTAssertFalse(message.contains("don't match"))
    }

    // MARK: Sign up

    /// The likeliest sign-up failure, and the one where the fix is to do
    /// something else entirely.
    func testAnAlreadyRegisteredEmailSaysToSignIn() {
        let message = AuthMessage.forSignUp(.server(status: 400, message: "email: Value must be unique."))

        XCTAssertTrue(message.lowercased().contains("already an account"))
        XCTAssertTrue(message.lowercased().contains("sign in"))
    }

    func testAShortPasswordSaysTheMinimum() {
        let message = AuthMessage.forSignUp(
            .server(status: 400, message: "password: The length must be at least 8.")
        )

        XCTAssertTrue(message.contains("8 characters"))
    }

    func testAMalformedEmailSaysSo() {
        let message = AuthMessage.forSignUp(.server(status: 400, message: "email: Must be a valid email address."))

        XCTAssertTrue(message.lowercased().contains("email address"))
        XCTAssertFalse(message.lowercased().contains("already an account"))
    }

    /// The generic top-level message with no field detail — what a server that
    /// did not report per-field errors would send. It must still be actionable
    /// rather than echoing "Failed to create record."
    func testAnUnrecognisedRejectionStillSaysWhatToCheck() {
        let message = AuthMessage.forSignUp(.server(status: 400, message: "Failed to create record."))

        XCTAssertTrue(message.contains("8 characters"))
        XCTAssertFalse(message.contains("Failed to create record."))
    }

    func testSignUpTransportFailureBlamesTheConnection() {
        XCTAssertTrue(AuthMessage.forSignUp(.transport("offline")).contains("Check your connection"))
    }
}
