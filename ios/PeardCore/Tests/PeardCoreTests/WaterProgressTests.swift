import XCTest
@testable import PeardCore

/// Today's water against the built-in daily targets (#321).
final class WaterProgressTests: XCTestCase {
    func testTheBuiltInTargetsAreAMinimumBelowARecommendedAmount() {
        XCTAssertEqual(WaterAmount.defaultMinimum, 1500)
        XCTAssertEqual(WaterAmount.defaultRecommended, 2000)
        XCTAssertLessThan(WaterAmount.defaultMinimum, WaterAmount.defaultRecommended)
    }

    func testNothingDrunkIsNoProgress() {
        let progress = WaterProgress(ml: 0)

        XCTAssertEqual(progress.stage, .none)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertFalse(progress.isMinimumMet)
        XCTAssertFalse(progress.isRecommendedMet)
        XCTAssertEqual(progress.remaining, 2000)
    }

    func testUnderTheMinimum() {
        let progress = WaterProgress(ml: 830)

        XCTAssertEqual(progress.stage, .underMinimum)
        XCTAssertEqual(progress.fraction, 0.415, accuracy: 0.0001)
        XCTAssertFalse(progress.isMinimumMet)
        XCTAssertFalse(progress.isRecommendedMet)
        XCTAssertEqual(progress.remaining, 1170)
    }

    func testJustUnderTheMinimumIsStillUnder() {
        XCTAssertEqual(WaterProgress(ml: 1499).stage, .underMinimum)
    }

    func testExactlyTheMinimumMeetsIt() {
        let progress = WaterProgress(ml: 1500)

        XCTAssertEqual(progress.stage, .minimumMet)
        XCTAssertTrue(progress.isMinimumMet)
        XCTAssertFalse(progress.isRecommendedMet)
        XCTAssertEqual(progress.fraction, 0.75, accuracy: 0.0001)
    }

    func testBetweenTheMinimumAndTheRecommendedAmount() {
        let progress = WaterProgress(ml: 1800)

        XCTAssertEqual(progress.stage, .minimumMet)
        XCTAssertTrue(progress.isMinimumMet)
        XCTAssertFalse(progress.isRecommendedMet)
        XCTAssertEqual(progress.remaining, 200)
    }

    func testExactlyTheRecommendedAmountMeetsTheGoal() {
        let progress = WaterProgress(ml: 2000)

        XCTAssertEqual(progress.stage, .recommendedMet)
        XCTAssertTrue(progress.isRecommendedMet)
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.remaining, 0)
    }

    func testOverTheRecommendedAmountStaysFull() {
        let progress = WaterProgress(ml: 3500)

        XCTAssertEqual(progress.stage, .recommendedMet)
        XCTAssertEqual(progress.fraction, 1, "a bar cannot be more than full")
        XCTAssertEqual(progress.remaining, 0)
    }

    func testTheMinimumMarkerSitsAlongTheSameScale() {
        XCTAssertEqual(WaterProgress(ml: 1).minimumFraction, 0.75, accuracy: 0.0001)
    }

    func testStagesAreOrderedByHowFarAlong() {
        XCTAssertLessThan(WaterProgress.Stage.none, .underMinimum)
        XCTAssertLessThan(WaterProgress.Stage.underMinimum, .minimumMet)
        XCTAssertLessThan(WaterProgress.Stage.minimumMet, .recommendedMet)
    }

    func testCustomTargetsAreHonoured() {
        let progress = WaterProgress(ml: 900, minimum: 800, recommended: 1000)

        XCTAssertEqual(progress.stage, .minimumMet)
        XCTAssertEqual(progress.fraction, 0.9, accuracy: 0.0001)
    }

    func testNonsenseInputsCannotBreakTheFractions() {
        let negative = WaterProgress(ml: -50)
        XCTAssertEqual(negative.ml, 0)
        XCTAssertEqual(negative.stage, .none)

        let inverted = WaterProgress(ml: 500, minimum: 3000, recommended: 1000)
        XCTAssertEqual(inverted.minimum, 1000, "a minimum cannot exceed the recommended amount")
        XCTAssertLessThanOrEqual(inverted.minimumFraction, 1)

        let zero = WaterProgress(ml: 100, minimum: 0, recommended: 0)
        XCTAssertEqual(zero.recommended, 1)
        XCTAssertEqual(zero.fraction, 1)
    }
}
