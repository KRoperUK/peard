import XCTest
@testable import PeardCore

final class HapticsTests: XCTestCase {
    func testEndingsAreDistinguishable() {
        XCTAssertEqual(Haptic.sent.feedback, .notification(.success))
        XCTAssertEqual(Haptic.cancelled.feedback, .notification(.warning))
        XCTAssertEqual(Haptic.failed.feedback, .notification(.error))
    }

    func testStartingASendIsLighterThanFinishingOne() {
        XCTAssertEqual(Haptic.momentTapped.feedback, .impact(.light))
        XCTAssertNotEqual(Haptic.momentTapped.feedback, Haptic.sent.feedback)
    }

    func testRewindAndReactionsHaveTheirOwnFeel() {
        let all: [Haptic] = [.momentTapped, .sent, .cancelled, .failed, .rewound, .reacted]
        XCTAssertEqual(Set(all.map { "\($0.feedback)" }).count, all.count)
    }
}
