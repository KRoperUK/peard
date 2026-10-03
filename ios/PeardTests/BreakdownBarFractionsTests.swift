import XCTest
@testable import Peard

/// The two-tone bar's arithmetic, pinned without rendering a view.
///
/// #301 was reported from a screenshot: the Loo row (You 29 · Laura 39) "appears
/// roughly half-filled". It was — the row was drawn against the window total
/// rather than against the busiest row, so a moment worth half of everything the
/// connection logs read as half a bar however lopsided its own split was. These
/// are the numbers from that screenshot.
final class BreakdownBarFractionsTests: XCTestCase {

    // MARK: The busiest row fills

    /// The top row is the yardstick, so it has to reach the full width.
    func testTheBusiestRowFillsTheBar() {
        let loo = BreakdownBarFractions(mine: 29, others: 39, busiest: 68)

        XCTAssertEqual(loo.mine + loo.others, 1, accuracy: 0.0001)
        XCTAssertEqual(loo.mine, 29.0 / 68.0, accuracy: 0.0001)
        XCTAssertEqual(loo.others, 39.0 / 68.0, accuracy: 0.0001)
    }

    // MARK: Other rows scale against it

    /// The bug: a quiet row must be shorter than the busiest one, and by its own
    /// share of it — not by its share of the whole window, which was short by
    /// however much the rest of the window held.
    func testAQuieterRowIsShorterThanTheBusiest() {
        let coffee = BreakdownBarFractions(mine: 25, others: 38, busiest: 68)

        XCTAssertEqual(coffee.mine + coffee.others, 63.0 / 68.0, accuracy: 0.0001)
        XCTAssertLessThan(coffee.mine + coffee.others, 1)
    }

    /// A moment only one person logs still draws, at its own width.
    func testASingleSidedRowDrawsOneSegment() {
        let toot = BreakdownBarFractions(mine: 48, others: 0, busiest: 68)

        XCTAssertEqual(toot.mine, 48.0 / 68.0, accuracy: 0.0001)
        XCTAssertEqual(toot.others, 0)
    }

    // MARK: The split is the point

    /// Neither side may be normalised away: 29 against 39 is not an even split,
    /// and the bar has to show the difference rather than flatten it to a half.
    func testTheTwoSidesStayUnequal() {
        let loo = BreakdownBarFractions(mine: 29, others: 39, busiest: 68)

        XCTAssertNotEqual(loo.mine, loo.others, accuracy: 0.0001)
        XCTAssertLessThan(loo.mine, loo.others)
        // Half of the row, not half of the window — what the tester actually saw.
        XCTAssertNotEqual(loo.mine + loo.others, 0.5, accuracy: 0.01)
    }

    // MARK: Degenerate input

    /// A window with nothing in it renders no rows, but the bar must not divide by
    /// zero if it is ever asked to.
    func testAZeroBusiestRowDrawsNothing() {
        let empty = BreakdownBarFractions(mine: 0, others: 0, busiest: 0)

        XCTAssertEqual(empty, BreakdownBarFractions(mine: 0, others: 0, busiest: 0))
        XCTAssertEqual(empty.mine, 0)
        XCTAssertEqual(empty.others, 0)
    }

    /// Counts cannot be negative, but a fraction of a bar cannot be either, so a
    /// stray value must not draw backwards.
    func testNegativeCountsClampToNothing() {
        let odd = BreakdownBarFractions(mine: -5, others: 10, busiest: 20)

        XCTAssertEqual(odd.mine, 0)
        XCTAssertEqual(odd.others, 0.5, accuracy: 0.0001)
    }
}
