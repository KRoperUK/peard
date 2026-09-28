import XCTest
@testable import PeardCore

/// Pinning moments to the front of the grid (issue #11).
final class MomentPinsTests: XCTestCase {
    private let beer = Moment(kind: .beer, emoji: "🍺", label: "Beer")
    private let loo = Moment(kind: .loo, emoji: "💩", label: "Loo")
    private let coffee = Moment(kind: .coffee, emoji: "☕", label: "Coffee")
    private let tea = Moment(kind: EventKind(rawValue: "tea"), emoji: "🫖", label: "Tea", origin: .custom(recordID: nil))

    private var all: [Moment] { [beer, loo, coffee, tea] }

    func testNothingPinnedKeepsTheUsualOrder() {
        XCTAssertEqual(MomentPins.ordered(all, pinned: []).map(\.label), ["Beer", "Loo", "Coffee", "Tea"])
    }

    /// In the order they were pinned — the last pin is not promoted over the
    /// first, which would move tiles every time somebody pins another.
    func testPinnedMomentsComeFirstInPinOrder() {
        XCTAssertEqual(MomentPins.ordered(all, pinned: ["tea", "coffee"]).map(\.label), ["Tea", "Coffee", "Beer", "Loo"])
    }

    func testAPinForAMomentThatHasGoneIsIgnored() {
        XCTAssertEqual(MomentPins.ordered(all, pinned: ["sauna", "loo"]).map(\.label), ["Loo", "Beer", "Coffee", "Tea"])
    }

    func testTogglingPinsAtTheEndAndUnpinsInPlace() {
        XCTAssertEqual(MomentPins.toggled("tea", in: ["beer"]), ["beer", "tea"])
        XCTAssertEqual(MomentPins.toggled("beer", in: ["beer", "tea"]), ["tea"])
    }

    func testPinsAreKeptPerConnection() {
        let suite = "pins-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: UserDefaults(suiteName: suite))

        store.setPinnedMoments(["tea"], forConnection: "flat")
        store.setPinnedMoments(["beer", "coffee"], forConnection: "pair")

        XCTAssertEqual(store.pinnedMoments(forConnection: "flat"), ["tea"])
        XCTAssertEqual(store.pinnedMoments(forConnection: "pair"), ["beer", "coffee"])
        XCTAssertEqual(store.pinnedMoments(forConnection: "other"), [])

        store.setPinnedMoments([], forConnection: "flat")
        XCTAssertEqual(store.pinnedMoments(forConnection: "flat"), [])
    }
}
