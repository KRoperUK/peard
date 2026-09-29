import XCTest

/// The first minute of a fresh install, driven through the real UI: the privacy
/// gate, the sign-in screen behind it, and an invite link arriving on either
/// side of the gate.
///
/// The unit tests already cover `AppModel`'s routing decisions; what they cannot
/// see is whether the screens those decisions pick actually appear and can be
/// tapped through. That is all this checks — deliberately a smoke test, not a
/// tour of the app.
///
/// One test walking the whole path rather than one per step, because each
/// launch and termination of the app costs far more than the steps themselves,
/// and the steps are in the order a real first launch meets them anyway. Each
/// is its own activity, so a failure still says which step it was.
///
/// No server. Everything here happens before sign-in, and the app is pointed at
/// a port nothing listens on (see `DebugSupport.serverURLEnvironmentKey`), so the
/// launch's health probe is refused at once rather than reaching a developer's
/// local server — and nothing here depends on one being there.
///
/// Slow, as UI tests are, so neither `make test-app` nor `fastlane test_app`
/// runs it: `make test-ui` and `fastlane test_ui` do, and CI runs it on pushes to
/// main.
final class LaunchSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Generous, because the first launch on a CI simulator that has just booted
    /// can take most of it.
    private let launchTimeout: TimeInterval = 30
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Both keys mirror DebugSupport, which the test bundle cannot import.
        app.launchArguments += ["-PeardResetState"]
        app.launchEnvironment["PEARD_SERVER_URL"] = "http://127.0.0.1:1"
    }

    func testFirstLaunchThroughConsentToAnInvite() {
        let agree = app.buttons["Agree to the privacy policy and continue"]
        let signInWithApple = app.buttons["Sign in with Apple"]
        let pairingCode = app.textFields["Pairing code"]

        XCTContext.runActivity(named: "A fresh install opens on the privacy policy") { _ in
            app.launch()
            XCTAssertTrue(agree.waitForExistence(timeout: launchTimeout), "the privacy consent screen never appeared")
        }

        // The pairing screen's first act is to talk to the server, and nothing
        // may do that before agreement — so the link must leave the gate up.
        XCTContext.runActivity(named: "An invite link before agreeing stays behind the gate") { _ in
            openInviteLink()
            XCTAssertTrue(agree.waitForExistence(timeout: timeout))
            XCTAssertFalse(pairingCode.waitForExistence(timeout: 2), "an invite link got past the privacy gate")
        }

        XCTContext.runActivity(named: "Agreeing leads to sign-in") { _ in
            agree.tap()
            XCTAssertTrue(signInWithApple.waitForExistence(timeout: timeout), "agreeing did not lead to the sign-in screen")
            XCTAssertFalse(agree.exists, "the consent screen is still showing behind sign-in")
            XCTAssertTrue(app.secureTextFields.firstMatch.exists, "no password field on the sign-in screen")
        }

        // What `AppModel.handle(url:)` does today for a signed-out user once the
        // launch has finished: any phase but `.loading` routes straight to
        // `.pair`. (A link that arrives *during* the launch is held instead, and
        // the user lands on sign-in with the code kept — a race the unit tests
        // cover, since they can hold the phase still.) If signed-out users
        // should be sent to sign in first, this is the step to change.
        XCTContext.runActivity(named: "An invite link on the sign-in screen opens pairing with the code") { _ in
            openInviteLink()
            XCTAssertTrue(pairingCode.waitForExistence(timeout: timeout), "the invite link did not open the pairing screen")
            XCTAssertEqual(pairingCode.value as? String, "ABC123")
        }
    }

    /// Opens `peard://pair/ABC123` the way a tap on it in another app would.
    ///
    /// Through the system rather than `XCUIApplication.open(_:)`, which
    /// relaunches the app to deliver the URL — with the launch arguments, so the
    /// reset would run again and put the consent screen back in front of every
    /// link. The system route hands the URL to the running app's `onOpenURL`,
    /// with no "Open in Pear'd?" prompt in between.
    private func openInviteLink() {
        XCUIDevice.shared.system.open(URL(string: "peard://pair/ABC123")!)
    }
}
