import XCTest
@testable import PeardCore

/// The record behind the gate in front of sign-in.
///
/// Worth its own suite because the interesting behaviour is what counts as
/// *not* consented: a fresh install and an install that agreed to a superseded
/// version both have to read as false, and only one of them is a first run.
final class PrivacyConsentTests: XCTestCase {
    private var suiteName: String!
    private var store: SharedStore!

    override func setUp() {
        super.setUp()
        suiteName = "privacy-consent-\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallHasNotConsented() {
        let consent = store.privacyConsent

        XCTAssertFalse(consent.hasAcceptedCurrentVersion)
        XCTAssertTrue(consent.isFirstRun)
        XCTAssertNil(consent.acceptedAt)
    }

    func testRecordingConsentStoresTheVersionAndTheDate() {
        let when = Date(timeIntervalSince1970: 1_785_000_000)

        store.recordPrivacyConsent(at: when)

        let consent = store.privacyConsent
        XCTAssertTrue(consent.hasAcceptedCurrentVersion)
        XCTAssertFalse(consent.isFirstRun)
        XCTAssertEqual(consent.acceptedVersion, PrivacyConsent.currentVersion)
        XCTAssertEqual(consent.acceptedAt, when)
    }

    /// The whole reason a version is stored rather than a boolean: agreeing to
    /// the old policy is not agreeing to the new one.
    func testASupersededVersionDoesNotCount() {
        store.recordPrivacyConsent(version: "1970-01-01")

        let consent = store.privacyConsent
        XCTAssertFalse(consent.hasAcceptedCurrentVersion)
        XCTAssertFalse(consent.isFirstRun, "they have agreed to something before — this is an update, not a first run")
    }

    func testClearingConsentPutsTheGateBack() {
        store.recordPrivacyConsent()

        store.clearPrivacyConsent()

        XCTAssertFalse(store.privacyConsent.hasAcceptedCurrentVersion)
        XCTAssertTrue(store.privacyConsent.isFirstRun)
    }

    /// Consent belongs to the installation, not the session — signing out must
    /// not silently re-ask, and more importantly must not silently *forget*.
    func testConsentSurvivesClearingWidgetCredentials() {
        store.recordPrivacyConsent()

        store.removeWidgetToken()
        store.selectedConnectionID = nil

        XCTAssertTrue(store.privacyConsent.hasAcceptedCurrentVersion)
    }

    /// The version string is rendered on the server's `/privacy` page as its
    /// "Last updated" date; a version that is not one is a sign the two have
    /// drifted apart.
    func testCurrentVersionIsAnISODate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        XCTAssertNotNil(formatter.date(from: PrivacyConsent.currentVersion))
    }
}
