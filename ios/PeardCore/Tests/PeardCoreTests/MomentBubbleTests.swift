import XCTest
@testable import PeardCore

final class MomentBubbleTests: XCTestCase {
    private let base = URL(string: "https://peard.example")!

    func testAMomentSurvivesTheTripThroughABubble() {
        let sent = MomentBubble(kind: .beer, emoji: "🍺", label: "Beer")
        XCTAssertEqual(MomentBubble(url: sent.url(base: base)), sent)
    }

    func testACustomMomentWithAwkwardCharactersSurvivesToo() {
        let sent = MomentBubble(kind: EventKind(rawValue: "dog_walk"), emoji: "🐕‍🦺", label: "Dog walk & treats?")
        XCTAssertEqual(MomentBubble(url: sent.url(base: base)), sent)
    }

    /// Opens the site on a device without the extension, and names nothing but
    /// the moment.
    func testTheURLIsTheSiteWithOnlyTheMoment() throws {
        let url = MomentBubble(kind: .coffee, emoji: "☕", label: "Coffee").url(base: base)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "peard.example")
        XCTAssertEqual(components.path, "/")
        XCTAssertEqual(Set(components.queryItems?.map(\.name) ?? []), ["peard_moment", "emoji", "label"])
    }

    func testOtherMessagesAreNotMoments() {
        XCTAssertNil(MomentBubble(url: nil))
        XCTAssertNil(MomentBubble(url: URL(string: "https://peard.example/")))
        XCTAssertNil(MomentBubble(url: URL(string: "https://example.com/?peard_moment=")))
    }

    func testCaption() {
        XCTAssertEqual(MomentBubble(kind: .beer, emoji: "🍺", label: "Beer").caption, "🍺 Beer logged")
    }
}
