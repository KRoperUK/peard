import XCTest
@testable import Peard
import PeardCore

/// Metric streaks on the recap (#391): steps and exercise get the same row the
/// water streak has, with the same "worth mentioning" bar. The server decides
/// the numbers; what is tested here is which rows the section keeps and the
/// words it puts on them.
@MainActor
final class RecapMetricStreakTests: XCTestCase {
    private func section(_ metrics: [MomentRecap.MetricStreak]) -> RecapSection {
        RecapSection(
            recap: MomentRecap(total: 4, mine: 3, others: 1, streak: .init(current: 2, best: 2), metricStreaks: metrics),
            mineLabel: "You",
            othersLabel: "Ari",
            waterEnabled: true
        )
    }

    /// A live run, or a best of more than a day — the same bar the moment and
    /// water streaks use. A metric that only ever managed one day stays quiet.
    func testOnlyMetricsWithARunAreShown() {
        let shown = section([
            .init(metric: "steps", current: 3, best: 3),
            .init(metric: "exercise", current: 0, best: 5),
            .init(metric: "flights", current: 0, best: 1),
        ]).shownMetricStreaks

        XCTAssertEqual(shown.map(\.metric), ["steps", "exercise"])
    }

    /// With nothing to say the list is empty, so a connection tracking no other
    /// metric draws no extra rows.
    func testNoMetricStreaksShowsNothing() {
        XCTAssertTrue(section([]).shownMetricStreaks.isEmpty)
    }

    /// The copy names the metric rather than saying "goal", so two rows on the
    /// same bar cannot be confused for each other.
    func testTheSentenceNamesTheMetric() {
        let steps = MomentRecap.MetricStreak(metric: "steps", current: 3, best: 5)

        XCTAssertEqual(
            RecapSection.metricStreakText(steps, definition: steps.definition),
            "3 days hitting your steps goal"
        )
        XCTAssertEqual(
            RecapSection.metricStreakText(
                MomentRecap.MetricStreak(metric: "steps", current: 1, best: 1),
                definition: steps.definition
            ),
            "1 day hitting your steps goal"
        )
    }

    /// A broken run still reports the best, which is the only reason to draw the
    /// row at all once the current run is gone.
    func testABrokenRunReportsTheBest() {
        let done = MomentRecap.MetricStreak(metric: "exercise", current: 0, best: 4)

        XCTAssertEqual(
            RecapSection.metricStreakText(done, definition: done.definition),
            "Exercise streak ended — best was 4 days hitting the goal"
        )
    }

    /// A custom metric the app has no built-in for still draws from its slug,
    /// rather than showing an empty row.
    func testACustomMetricResolvesToAFallbackDefinition() {
        let custom = MomentRecap.MetricStreak(metric: "flights", current: 2, best: 2)

        XCTAssertFalse(custom.definition.label.isEmpty)
        XCTAssertFalse(custom.definition.emoji.isEmpty)
    }

    /// Streak milestones are the days worth a celebration (#421): a week, a
    /// month, a hundred, a year — and nothing in between.
    func testStreakMilestones() {
        for day in [7, 30, 100, 365] {
            XCTAssertTrue(RecapSection.isStreakMilestone(day), "\(day) is a milestone")
        }
        for day in [0, 1, 6, 8, 29, 99, 364, 366] {
            XCTAssertFalse(RecapSection.isStreakMilestone(day), "\(day) is not a milestone")
        }
    }
}
