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

/// Invite links as https, which is what an invite is actually shared as.
extension DeepLinkTests {
    func testAWebInviteOpensThePairingScreen() {
        XCTAssertEqual(
            DeepLink.parse(URL(string: "https://peard.kroper.uk/c/ABC123")!),
            .pair(code: "ABC123")
        )
    }

    /// The code is upper-cased, like the custom-scheme form, so a link typed or
    /// mangled in lower case still matches.
    func testAWebInviteCodeIsUpperCased() {
        XCTAssertEqual(
            DeepLink.parse(URL(string: "https://peard.kroper.uk/c/abc123")!),
            .pair(code: "ABC123")
        )
    }

    /// The important one. An associated domain hands the app every matching
    /// https URL on the host, and the privacy policy lives on the same host —
    /// a policy that opens the app instead of a web page is both wrong and, to
    /// an app-store reviewer, unreadable.
    func testThePrivacyPolicyIsNotAnInvite() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk/privacy")!))
    }

    func testTheHomePageIsNotAnInvite() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk/")!))
    }

    /// Another host's /c/ path is not ours, however similar it looks.
    func testAnotherHostIsIgnored() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://example.com/c/ABC123")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk.evil.com/c/ABC123")!))
    }

    /// A trailing segment is not a code — `/c/ABC123/extra` is not a route this
    /// app knows, and guessing would open the pairing screen on nonsense.
    func testAnOverlongPathIsIgnored() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk/c/ABC123/extra")!))
    }

    func testAMissingCodeIsIgnored() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk/c/")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://peard.kroper.uk/c")!))
    }

    /// The shared link is built from the public host, not the configured
    /// server: a dev address is no use to whoever receives the message.
    func testTheSharedLinkUsesThePublicHost() {
        XCTAssertEqual(
            DeepLink.inviteLink(code: "ABC123").absoluteString,
            "https://peard.kroper.uk/c/ABC123"
        )
    }

    /// And the share message carries it rather than the server's `peard://`
    /// deep link, which is "Safari cannot open the page" to anybody without the
    /// app installed.
    func testTheShareMessageCarriesTheWebLink() {
        let invite = PairInvite(
            code: "ABC123",
            expires: Date(timeIntervalSince1970: 0),
            deepLink: "peard://pair/ABC123"
        )

        XCTAssertTrue(invite.shareMessage.contains("https://peard.kroper.uk/c/ABC123"))
        XCTAssertFalse(invite.shareMessage.contains("peard://"))
    }
}

/// Appending a file token to an image path.
///
/// `posts.media` is a protected file field: without `?token=` the server
/// answers 404, and joining the query wrongly produces exactly that — so the
/// rule is worth asserting rather than eyeballing.
final class FileTokenDecorationTests: XCTestCase {
    func testABarePathGetsAQuestionMark() {
        XCTAssertEqual(
            FileTokenStore.decorate("/api/files/posts/p1/photo.jpg", token: "abc"),
            "/api/files/posts/p1/photo.jpg?token=abc"
        )
    }

    /// The thumbnail path already carries a query, which is the common case —
    /// every timeline row and the home hero use it.
    func testAPathWithAQueryGetsAnAmpersand() {
        XCTAssertEqual(
            FileTokenStore.decorate("/api/files/posts/p1/photo.jpg?thumb=512x512", token: "abc"),
            "/api/files/posts/p1/photo.jpg?thumb=512x512&token=abc"
        )
    }

    /// A real JWT is base64url — alphanumerics, `-`, `_` and `.` — and must
    /// survive untouched, or every image 404s.
    func testAJWTPassesThroughUnchanged() {
        let jwt = "eyJhbGc.eyJpZCI6-_x.SflKxwRJ"

        XCTAssertEqual(FileTokenStore.decorate("/f.jpg", token: jwt), "/f.jpg?token=" + jwt)
    }

    /// Anything outside the unreserved set is escaped. `+` especially: a great
    /// many servers decode it as a space, which would turn a valid token into a
    /// rejected one for no visible reason.
    func testQuerySignificantCharactersAreEscaped() {
        let decorated = FileTokenStore.decorate("/f.jpg", token: "a+b/c=d&e")

        XCTAssertEqual(decorated, "/f.jpg?token=a%2Bb%2Fc%3Dd%26e")
    }

    /// No token is not a token. Appending an empty one would produce a URL that
    /// looks authenticated and is not.
    func testAnEmptyTokenIsNotAppended() {
        XCTAssertEqual(FileTokenStore.decorate("/f.jpg", token: ""), "/f.jpg")
    }
}

/// Following the phone, or not.
final class AppearancePreferenceTests: XCTestCase {
    /// Following the system is the default and stays it. An app that decides
    /// for itself on first launch is an app ignoring a setting somebody already
    /// made once, at the system level.
    func testTheDefaultIsToFollowTheSystem() {
        XCTAssertEqual(AppearancePreference.default, .system)
        XCTAssertEqual(AppearancePreference(storedValue: nil), .system)
    }

    /// A value written by a later build, or a corrupted default, must not be a
    /// launch failure.
    func testAnUnknownStoredValueFallsBack() {
        XCTAssertEqual(AppearancePreference(storedValue: "sepia"), .system)
        XCTAssertEqual(AppearancePreference(storedValue: ""), .system)
    }

    func testEachChoiceRoundTripsThroughStorage() {
        for preference in AppearancePreference.allCases {
            XCTAssertEqual(AppearancePreference(storedValue: preference.rawValue), preference)
        }
    }

    /// All three are offered, in the order the picker shows them.
    func testTheOrderIsSystemLightDark() {
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
    }
}
