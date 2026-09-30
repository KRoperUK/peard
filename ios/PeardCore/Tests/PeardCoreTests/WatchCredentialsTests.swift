import XCTest
@testable import PeardCore

final class WatchCredentialsTests: XCTestCase {
    private var suiteName: String!
    private var store: SharedStore!

    override func setUp() {
        super.setUp()
        suiteName = "peard-watch-\(UUID().uuidString)"
        store = SharedStore(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    func testCredentialsSurviveTheTripToTheWatch() throws {
        let sent = WatchCredentials(token: "widget-token", baseURL: URL(string: "https://peard.example")!)

        XCTAssertTrue(WatchCredentials.apply(sent.applicationContext, to: store))

        XCTAssertEqual(store.widgetToken, "widget-token")
        XCTAssertEqual(store.apiBaseURL, URL(string: "https://peard.example"))
        XCTAssertEqual(WatchCredentials(store: store), sent)
    }

    func testSigningOutOnThePhoneClearsTheWatch() {
        store.writeWidgetCredentials(token: "widget-token", baseURL: URL(string: "https://peard.example")!)

        XCTAssertFalse(WatchCredentials.apply(WatchCredentials.signedOutContext, to: store))

        XCTAssertNil(store.widgetToken)
        XCTAssertNil(WatchCredentials(store: store))
    }

    func testNothingIsSentWhileSignedOut() {
        XCTAssertNil(WatchCredentials(store: store))
    }

    func testAMalformedContextIsNotCredentials() {
        XCTAssertNil(WatchCredentials(applicationContext: [:]))
        XCTAssertNil(WatchCredentials(applicationContext: ["widgetToken": "t"]))
        XCTAssertNil(WatchCredentials(applicationContext: ["widgetToken": 42, "apiBaseUrl": "https://x"]))
    }
}
