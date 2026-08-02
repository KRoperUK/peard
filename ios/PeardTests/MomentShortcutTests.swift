import XCTest
@testable import Peard
import PeardCore

/// What the Shortcuts pickers offer, and why an option always knows where it is
/// going.
final class MomentShortcutTests: XCTestCase {
    private let flatmates = ConnectionEntity(id: "p1", title: "Flatmates", subtitle: "3 people")

    private func available(_ kind: String, _ emoji: String, _ label: String) -> WidgetFeed.AvailableMoment {
        WidgetFeed.AvailableMoment(kind: EventKind(rawValue: kind), emoji: emoji, label: label)
    }

    // MARK: The built-ins

    /// The three the server accepts in any connection, which is what lets them
    /// be offered without one.
    func testTheBuiltInsAreTheThree() {
        XCTAssertEqual(MomentOption.builtins.map(\.kind), ["beer", "loo", "coffee"])
    }

    /// No pair, so they fall through to whichever connection is liveliest — the
    /// same fallback an unconfigured widget uses.
    func testBuiltInsCarryNoConnection() {
        XCTAssertTrue(MomentOption.builtins.allSatisfy { $0.pairID == nil })
        XCTAssertTrue(MomentOption.builtins.allSatisfy { $0.connectionTitle == nil })
    }

    // MARK: The whole list

    private func flatmatesWith(_ moments: [WidgetFeed.AvailableMoment]) -> [(ConnectionEntity, [WidgetFeed.AvailableMoment])] {
        [(flatmates, moments)]
    }

    /// The built-ins lead, then whatever the connections invented.
    func testCustomMomentsFollowTheBuiltIns() {
        let options = MomentOption.all(from: flatmatesWith([
            available("beer", "\u{1F37A}", "Beer"),
            available("dog_walk", "\u{1F415}", "Dog walk"),
        ]))

        XCTAssertEqual(options.map(\.kind), ["beer", "loo", "coffee", "dog_walk"])
    }

    /// Once, unbound — not once per connection. Three options times however many
    /// connections somebody has is a picker nobody can read, and a built-in is
    /// valid everywhere so one entry serves them all.
    func testBuiltInsAreNotRepeatedPerConnection() {
        let sam = ConnectionEntity(id: "p2", title: "Sam", subtitle: "Just the two of you")
        let builtins = [available("beer", "\u{1F37A}", "Beer"), available("loo", "\u{1F4A9}", "Loo")]

        let options = MomentOption.all(from: [(flatmates, builtins), (sam, builtins)])

        XCTAssertEqual(options.filter { $0.kind == "beer" }.count, 1)
        XCTAssertNil(options.first { $0.kind == "beer" }?.pairID)
    }

    /// A custom moment is bound to the connection that published it, because the
    /// server refuses a kind a connection does not have.
    func testACustomMomentCarriesItsConnection() {
        let options = MomentOption.all(from: flatmatesWith([available("dog_walk", "\u{1F415}", "Dog walk")]))
        let walk = options.first { $0.kind == "dog_walk" }

        XCTAssertEqual(walk?.pairID, "p1")
        XCTAssertEqual(walk?.connectionTitle, "Flatmates")
    }

    /// Two connections that both invented "Dog walk" are two options, not one
    /// ambiguous one — which is why the stored value carries the pair.
    func testTheSameKindInTwoConnectionsGivesTwoDistinctOptions() {
        let sam = ConnectionEntity(id: "p2", title: "Sam", subtitle: "Just the two of you")
        let walk = available("dog_walk", "\u{1F415}", "Dog walk")

        let options = MomentOption.all(from: [(flatmates, [walk]), (sam, [walk])])
        let walks = options.filter { $0.kind == "dog_walk" }

        XCTAssertEqual(walks.map(\.pairID), ["p1", "p2"])
        XCTAssertNotEqual(walks[0].encoded, walks[1].encoded)
    }

    /// A connection with nothing published contributes nothing, and the picker
    /// is still usable — the built-ins are always there.
    func testAConnectionWithNoCustomMomentsAddsNothing() {
        let options = MomentOption.all(from: flatmatesWith([]))

        XCTAssertEqual(options.map(\.kind), ["beer", "loo", "coffee"])
    }

    // MARK: Display

    /// The picker names the connection only on the options that belong to one.
    func testTheConnectionIsNamedOnlyWhenThereIsOne() {
        let options = MomentOption.all(from: flatmatesWith([available("dog_walk", "\u{1F415}", "Dog walk")]))

        XCTAssertNil(options.first { $0.kind == "beer" }?.connectionTitle)
        XCTAssertEqual(options.first { $0.kind == "dog_walk" }?.connectionTitle, "Flatmates")
    }


    // MARK: The stored value

    /// The parameter is a string because Shortcuts would not give an AppEntity
    /// back — `entities(for:)` was never called, so a stored entity never
    /// resolved and the action ran with nothing. A string round-trips or the
    /// feature does not work at all, so it is worth asserting directly.
    func testAnOptionSurvivesBeingStoredAndReadBack() {
        let walk = MomentOption(
            kind: "dog_walk", emoji: "\u{1F415}", label: "Dog walk",
            pairID: "p1", connectionTitle: "Flatmates"
        )

        let restored = MomentOption(encoded: walk.encoded)

        XCTAssertEqual(restored.kind, "dog_walk")
        XCTAssertEqual(restored.emoji, "\u{1F415}")
        XCTAssertEqual(restored.label, "Dog walk")
        XCTAssertEqual(restored.pairID, "p1")
    }

    /// A built-in stores no pair, and must read back with none rather than an
    /// empty string that would be sent as a connection id.
    func testABuiltInReadsBackWithNoConnection() {
        let restored = MomentOption(encoded: MomentOption.builtins[0].encoded)

        XCTAssertNil(restored.pairID)
        XCTAssertEqual(restored.kind, "beer")
    }

    /// A shortcut saved by an earlier build stored a bare slug. It should still
    /// log rather than fail — the emoji and label come from the catalogue.
    func testABareSlugStillResolves() {
        let restored = MomentOption(encoded: "coffee")

        XCTAssertEqual(restored.kind, "coffee")
        XCTAssertEqual(restored.emoji, "\u{2615}")
        XCTAssertEqual(restored.label, "Coffee")
        XCTAssertNil(restored.pairID)
    }

    /// A label with a space, an emoji and punctuation in it must not break the
    /// packing — the separator is a control character precisely so it cannot
    /// collide with anything somebody types.
    func testAnAwkwardLabelSurvives() {
        let option = MomentOption(kind: "tea_time", emoji: "\u{1F375}", label: "Tea: 4 o'clock", pairID: "p9")

        let restored = MomentOption(encoded: option.encoded)

        XCTAssertEqual(restored.label, "Tea: 4 o'clock")
        XCTAssertEqual(restored.pairID, "p9")
    }

    // MARK: Connections

    func testAConnectionEntityTakesItsSubtitleFromTheConnection() {
        let group = ConnectionEntity(WidgetConnection(id: "p1", title: "Flatmates", memberCount: 3, isGroup: true))
        let pair = ConnectionEntity(WidgetConnection(id: "p2", title: "Sam", memberCount: 2, isGroup: false))

        XCTAssertEqual(group.subtitle, "3 people")
        XCTAssertEqual(pair.subtitle, "Just the two of you")
    }
}
