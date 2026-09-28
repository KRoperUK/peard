import XCTest
@testable import PeardCore

/// What the configurable Control Centre control logs, and where. The picker's
/// own options are covered by `MomentShortcutTests` in the app's tests.
final class MomentOptionTests: XCTestCase {
    // MARK: An unconfigured control

    /// A control is drawn before it is set up, and must still do something when
    /// tapped: a beer, as the fixed beer control always has.
    func testNoStoredMomentMeansABeer() {
        let option = MomentOption(storedOrDefault: nil)

        XCTAssertEqual(option.kind, "beer")
        XCTAssertEqual(option.emoji, "🍺")
        XCTAssertNil(option.pairID)
    }

    /// An empty string would otherwise go to the server as a moment with no
    /// kind, which it refuses.
    func testAnEmptyStoredMomentMeansABeer() {
        XCTAssertEqual(MomentOption(storedOrDefault: "").kind, "beer")
    }

    func testAStoredMomentIsReadBack() {
        let walk = MomentOption(kind: "dog_walk", emoji: "🐕", label: "Dog walk", pairID: "p1")

        let restored = MomentOption(storedOrDefault: walk.encoded)

        XCTAssertEqual(restored.kind, "dog_walk")
        XCTAssertEqual(restored.label, "Dog walk")
        XCTAssertEqual(restored.pairID, "p1")
    }

    // MARK: Where it goes

    /// A built-in is valid anywhere, so the chosen connection decides.
    func testABuiltInGoesToTheChosenConnection() {
        XCTAssertEqual(MomentOption.builtins[0].pairID(fallingBackTo: "p2"), "p2")
    }

    /// Nothing chosen: nil, which the server reads as the liveliest connection.
    func testABuiltInWithNoConnectionGoesToTheLiveliest() {
        XCTAssertNil(MomentOption.builtins[0].pairID(fallingBackTo: nil))
    }

    /// A custom moment exists only in the connection that published it; sending
    /// it to the one chosen beside it would be refused with a 400.
    func testACustomMomentKeepsItsOwnConnection() {
        let walk = MomentOption(kind: "dog_walk", emoji: "🐕", label: "Dog walk", pairID: "p1")

        XCTAssertEqual(walk.pairID(fallingBackTo: "p2"), "p1")
    }
}
