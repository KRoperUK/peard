import XCTest
@testable import PeardCore

final class MetricDefinitionTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")

    // MARK: MetricProgress

    func testProgressStagesAndFraction() {
        let none = MetricProgress(amount: 0, minimum: 20, goal: 100)
        XCTAssertEqual(none.stage, .none)
        XCTAssertEqual(none.fraction, 0)

        let under = MetricProgress(amount: 10, minimum: 20, goal: 100)
        XCTAssertEqual(under.stage, .underMinimum)
        XCTAssertEqual(under.fraction, 0.1, accuracy: 0.0001)

        let min = MetricProgress(amount: 50, minimum: 20, goal: 100)
        XCTAssertEqual(min.stage, .minimumMet)
        XCTAssertFalse(min.isGoalMet)

        let met = MetricProgress(amount: 120, minimum: 20, goal: 100)
        XCTAssertEqual(met.stage, .goalMet)
        XCTAssertEqual(met.fraction, 1, "fraction caps at 1 however far over")
        XCTAssertEqual(met.remaining, 0)
    }

    func testProgressClampsDegenerateInputs() {
        let p = MetricProgress(amount: -5, minimum: 999, goal: 0)
        XCTAssertEqual(p.amount, 0, "a negative amount is none")
        XCTAssertEqual(p.goal, 1, "a goal below 1 is raised so the fraction never divides by zero")
        XCTAssertLessThanOrEqual(p.minimum, p.goal, "a minimum above the goal is pulled down")
        XCTAssertLessThanOrEqual(p.fraction, 1)
    }

    // MARK: MetricUnit

    func testUnitLabels() {
        XCTAssertEqual(MetricUnit.count.label(8000, locale: gb), "8,000")
        XCTAssertEqual(MetricUnit.minutes.label(30, locale: gb), "30 min")
        XCTAssertEqual(MetricUnit.millilitres.label(1500, locale: gb), "1,500 ml")
    }

    func testUnitParseRejectsNonDigitsAndRange() {
        XCTAssertEqual(MetricUnit.count.parse("5000", maximum: 200_000), 5000)
        XCTAssertNil(MetricUnit.count.parse("5.5", maximum: 200_000), "a decimal is a guess")
        XCTAssertNil(MetricUnit.count.parse("30 min", maximum: 200_000), "a unit is a guess")
        XCTAssertNil(MetricUnit.count.parse("0", maximum: 200_000), "zero is not an amount")
        XCTAssertNil(MetricUnit.count.parse("999999", maximum: 1000), "over the ceiling is rejected")
    }

    func testUnknownUnitFallsBackToCount() {
        XCTAssertEqual(MetricUnit(storedValue: "furlongs"), .count)
        XCTAssertEqual(MetricUnit(storedValue: nil), .count)
        XCTAssertEqual(MetricUnit(storedValue: "millilitres"), .millilitres)
    }

    // MARK: MetricDefinition / MetricCatalogue

    func testWaterBuiltinMatchesWaterAmountDefaults() {
        let water = MetricCatalogue.water
        XCTAssertEqual(water.slug, .water)
        XCTAssertEqual(water.unit, .millilitres)
        XCTAssertEqual(water.defaultMinimum, WaterAmount.defaultMinimum)
        XCTAssertEqual(water.defaultGoal, WaterAmount.defaultRecommended)
        XCTAssertEqual(water.maximum, WaterAmount.maximum)
        XCTAssertEqual(water.presets, WaterAmount.presets.map(\.ml))
    }

    func testBuiltinResolutionAndFallback() {
        XCTAssertEqual(MetricCatalogue.resolve(.water), MetricCatalogue.water)
        XCTAssertEqual(MetricCatalogue.resolve(EventKind(rawValue: "steps")), MetricCatalogue.steps)
        XCTAssertTrue(MetricCatalogue.isBuiltinMetric(.water))
        XCTAssertFalse(MetricCatalogue.isBuiltinMetric(EventKind(rawValue: "mystery")))

        let custom = MetricCatalogue.resolve(
            EventKind(rawValue: "pushups"), label: "Push-ups", emoji: "💪", goal: 50)
        XCTAssertEqual(custom.label, "Push-ups")
        XCTAssertEqual(custom.emoji, "💪")
        XCTAssertEqual(custom.defaultGoal, 50)
        XCTAssertEqual(custom.unit, .count)
    }

    func testReadoutUsesLabelForBareCounts() {
        XCTAssertEqual(MetricCatalogue.steps.readout(8000, locale: gb), "8,000 steps")
        XCTAssertEqual(MetricCatalogue.exercise.readout(30, locale: gb), "30 min")
        XCTAssertEqual(MetricCatalogue.water.readout(1500, locale: gb), "1,500 ml")
    }

    func testProgressWithPerMemberOverride() {
        // The hero's own target overrides the built-in goal.
        let p = MetricCatalogue.water.progress(amount: 1200, minimum: 1000, goal: 2400)
        XCTAssertEqual(p.goal, 2400)
        XCTAssertEqual(p.minimum, 1000)
        XCTAssertFalse(p.isGoalMet)
    }
}
