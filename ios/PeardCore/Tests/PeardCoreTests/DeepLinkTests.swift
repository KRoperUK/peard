import XCTest
@testable import PeardCore

/// Requirement 19 — `peard://` routing.
final class DeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLink.parse(url)
    }

    func testPairLinkUpperCasesTheCode() {
        XCTAssertEqual(parse("peard://pair/ab12cd"), .pair(code: "AB12CD"))
        XCTAssertEqual(parse("peard://pair/AB12CD"), .pair(code: "AB12CD"))
    }

    func testPairLinkWithoutACodeIsIgnored() {
        XCTAssertNil(parse("peard://pair"))
        XCTAssertNil(parse("peard://pair/"))
    }

    func testHomeLink() {
        XCTAssertEqual(parse("peard://home"), .home)
        XCTAssertEqual(parse("peard://home/"), .home)
    }

    func testGoogleCallback() {
        let url = URL(string: "peard://auth/google?code=abc&state=xyz")!
        XCTAssertEqual(DeepLink.parse(url), .googleCallback(url))
    }

    func testAuthLinkForAnotherProviderIsIgnored() {
        XCTAssertNil(parse("peard://auth/apple"))
        XCTAssertNil(parse("peard://auth"))
    }

    func testUnknownRoutesAndSchemesAreIgnored() {
        XCTAssertNil(parse("peard://settings"))
        XCTAssertNil(parse("https://peard.app/pair/AB12CD"))
        XCTAssertNil(parse("peard://"))
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertEqual(parse("PEARD://home"), .home)
    }
}

/// Requirement 3.1, 3.2 — server URL resolution.
final class PeardServerURLTests: XCTestCase {
    func testAcceptsAbsoluteURL() {
        XCTAssertEqual(
            PeardServerURL.resolve("http://192.168.1.42:8090"),
            URL(string: "http://192.168.1.42:8090")
        )
        XCTAssertEqual(
            PeardServerURL.resolve("https://peard.example.com"),
            URL(string: "https://peard.example.com")
        )
    }

    func testStripsTrailingSlash() {
        XCTAssertEqual(
            PeardServerURL.resolve("http://127.0.0.1:8090/"),
            URL(string: "http://127.0.0.1:8090")
        )
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(
            PeardServerURL.resolve("  http://127.0.0.1:8090  "),
            URL(string: "http://127.0.0.1:8090")
        )
    }

    func testFallsBackForMissingEmptyOrRelativeValues() {
        XCTAssertEqual(PeardServerURL.resolve(nil), PeardServerURL.fallback)
        XCTAssertEqual(PeardServerURL.resolve(""), PeardServerURL.fallback)
        XCTAssertEqual(PeardServerURL.resolve("   "), PeardServerURL.fallback)
        XCTAssertEqual(PeardServerURL.resolve("127.0.0.1:8090"), PeardServerURL.fallback)
        XCTAssertEqual(PeardServerURL.resolve("/api"), PeardServerURL.fallback)
    }

    /// An xcconfig variable that was never substituted must not be treated as
    /// a URL.
    func testFallsBackForUnsubstitutedPlaceholder() {
        XCTAssertEqual(PeardServerURL.resolve("$(PEARD_SERVER_SCHEME)://$(PEARD_SERVER_HOST)"), PeardServerURL.fallback)
        XCTAssertEqual(PeardServerURL.resolve("://"), PeardServerURL.fallback)
    }

    func testFallbackIsLoopback() {
        XCTAssertEqual(PeardServerURL.fallback.absoluteString, "http://127.0.0.1:8090")
    }
}
