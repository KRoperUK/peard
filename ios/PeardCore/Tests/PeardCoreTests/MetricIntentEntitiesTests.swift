import XCTest
@testable import PeardCore

/// The metric picker's entity (#392): a slug and how it is drawn, resolved from
/// a feed summary. Pure, so it is covered here rather than on a watch.
final class MetricIntentEntitiesTests: XCTestCase {
    private func summary(
        slug: String,
        label: String = "Steps",
        emoji: String = "👟",
        unit: String = "count",
        today: Int = 4200,
        goal: Int = 10000
    ) -> WidgetFeed.MetricSummary {
        WidgetFeed.MetricSummary(slug: slug, label: label, emoji: emoji, unitRaw: unit, today: today, goal: goal)
    }

    func testAnEntityTakesItsIdentityAndLookFromTheSummary() {
        let entity = MetricEntity(summary(slug: "steps", label: "Steps", emoji: "👟"))

        XCTAssertEqual(entity.id, "steps", "the slug is what a stored configuration matches back")
        XCTAssertEqual(entity.title, "Steps")
        XCTAssertEqual(entity.emoji, "👟")
    }

    /// The entity carries only the slug, never the amount or the goal, so a
    /// figure cannot be frozen into a face — the provider resolves it from the
    /// feed at render time, which is what lets a metric that has gone fall back.
    func testAnEntityCarriesNoAmountOrGoal() {
        let entity = MetricEntity(summary(slug: "water", label: "Water", emoji: "💧", unit: "millilitres"))

        XCTAssertEqual(entity.id, "water")
        XCTAssertEqual(entity.title, "Water")
    }

    func testTheDirectInitialiserKeepsTheSlugAsIdentity() {
        let entity = MetricEntity(id: "exercise", title: "Exercise", emoji: "🏃")

        XCTAssertEqual(entity.id, "exercise")
        XCTAssertEqual(entity.title, "Exercise")
        XCTAssertEqual(entity.emoji, "🏃")
    }
}
