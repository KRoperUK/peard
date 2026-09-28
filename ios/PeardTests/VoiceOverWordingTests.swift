import XCTest
@testable import Peard
import PeardCore

/// What VoiceOver is told about the moment grid and the timeline rows (issue #68).
@MainActor
final class VoiceOverWordingTests: XCTestCase {
    // MARK: Moment grid hint

    /// The countdown is only true when nothing holds the send.
    func testHomeHintMentionsTheCountdownOnlyWhenTheSendIsNotHeld() {
        XCTAssertEqual(
            MomentGrid.hint(purpose: .send, isPending: false, sendIsHeld: false),
            "Sends in \(Int(QuickSend.delay)) seconds unless you add a note"
        )
        let held = MomentGrid.hint(purpose: .send, isPending: false, sendIsHeld: true)
        XCTAssertFalse(held.contains("seconds"), held)
    }

    /// Tapping the moment already counting down sends it at once.
    func testHomeHintOnThePendingMomentSaysItSendsNow() {
        XCTAssertEqual(MomentGrid.hint(purpose: .send, isPending: true, sendIsHeld: false), "Sends it now")
        XCTAssertEqual(MomentGrid.hint(purpose: .send, isPending: true, sendIsHeld: true), "Sends it now")
    }

    /// In the photo sheet nothing is sent, whatever is running.
    func testPickerHintNeverTalksAboutSending() {
        for held in [false, true] {
            XCTAssertEqual(
                MomentGrid.hint(purpose: .pick, isPending: false, sendIsHeld: held),
                "Chooses this moment for the photo"
            )
            XCTAssertEqual(MomentGrid.hint(purpose: .pick, isPending: true, sendIsHeld: held), "Clears the choice")
        }
    }

    // MARK: Timeline reactions

    private let names = ["me": "you", "sam": "Sam", "alex": "Alex"]

    private func spoken(_ reactions: [(String, ReactionKind)]) -> String? {
        HistoryModel.spokenReactions(
            reactions.enumerated().map { Reaction(id: "r\($0.offset)", post: "p", user: $0.element.0, kind: $0.element.1) }
        ) { names[$0] ?? "Someone" }
    }

    func testNoReactionsSaysNothing() {
        XCTAssertNil(spoken([]))
    }

    func testOneReactionSaysWhatAndWho() {
        XCTAssertEqual(spoken([("sam", .heart)]), "Reactions: Heart from Sam")
    }

    /// Grouped by kind in the order the row draws them, people joined as a list.
    func testSeveralReactionsAreGroupedByKind() {
        XCTAssertEqual(
            spoken([("sam", .heart), ("alex", .cheers), ("me", .heart)]),
            "Reactions: Heart from Sam and you; Cheers from Alex"
        )
    }

    func testTheSamePersonIsNotNamedTwiceForOneKind() {
        XCTAssertEqual(spoken([("sam", .heart), ("sam", .heart)]), "Reactions: Heart from Sam")
    }
}
