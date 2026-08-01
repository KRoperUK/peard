import XCTest
@testable import PeardCore

/// What the timeline filter turns into, and the one combination that would
/// silently match nothing.
final class TimelineFilterTests: XCTestCase {
    func testNoFilterIsNotActiveAndAddsNothing() {
        XCTAssertFalse(TimelineFilter.none.isActive)
        XCTAssertTrue(TimelineFilter.none.clauses.isEmpty)
    }

    func testAPersonBecomesAnAuthorClause() {
        let filter = TimelineFilter(author: "u1")

        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.clauses, [#"author = "u1""#])
    }

    func testAKindBecomesAnEventKindClause() {
        let filter = TimelineFilter(kind: .coffee)

        XCTAssertEqual(filter.clauses, [#"event_kind = "coffee""#])
    }

    func testPhotosBecomeATypeClause() {
        let filter = TimelineFilter(photosOnly: true)

        XCTAssertEqual(filter.clauses, [#"type = "photo""#])
    }

    /// One person's coffees is a reasonable question, which is why these are
    /// separate fields rather than one enum.
    func testAPersonAndAKindCombine() {
        let filter = TimelineFilter(author: "u1", kind: .beer)

        XCTAssertEqual(filter.clauses, [#"author = "u1""#, #"event_kind = "beer""#])
    }

    /// A photo has no `event_kind`, so asking for both would always match
    /// nothing — which reads as a broken timeline rather than an impossible
    /// question. Photos win, being the thing just chosen.
    func testPhotosAndAKindCannotBothApply() {
        let filter = TimelineFilter(kind: .coffee, photosOnly: true)

        XCTAssertEqual(filter.clauses, [#"type = "photo""#])
    }

    // MARK: Choosing

    func testChoosingAKindTurnsPhotosOff() {
        let filter = TimelineFilter(author: "u1", photosOnly: true).choosing(kind: .loo)

        XCTAssertEqual(filter.author, "u1", "the person survives a change of moment")
        XCTAssertEqual(filter.kind, .loo)
        XCTAssertFalse(filter.photosOnly)
    }

    func testChoosingPhotosTurnsTheKindOff() {
        let filter = TimelineFilter(author: "u1", kind: .beer).choosingPhotos(true)

        XCTAssertEqual(filter.author, "u1")
        XCTAssertNil(filter.kind)
        XCTAssertTrue(filter.photosOnly)
    }

    func testChoosingAPersonLeavesTheMomentAlone() {
        let filter = TimelineFilter(kind: .beer).choosing(author: "u2")

        XCTAssertEqual(filter.author, "u2")
        XCTAssertEqual(filter.kind, .beer)
    }

    func testClearingEachDimensionIndependently() {
        let both = TimelineFilter(author: "u1", kind: .beer)

        XCTAssertEqual(both.choosing(author: nil).clauses, [#"event_kind = "beer""#])
        XCTAssertEqual(both.choosing(kind: nil).clauses, [#"author = "u1""#])
        XCTAssertFalse(both.choosing(author: nil).choosing(kind: nil).isActive)
    }

    /// An empty string is not a filter. It would produce `author = ""`, which
    /// matches nothing at all.
    func testEmptyValuesAreIgnored() {
        XCTAssertTrue(TimelineFilter(author: "").clauses.isEmpty)
        XCTAssertTrue(TimelineFilter(kind: EventKind(rawValue: "")).clauses.isEmpty)
    }

    /// A moment kind a connection invented is filterable like any other —
    /// `EventKind` is an open enum for exactly this.
    func testACustomKindFilters() {
        let filter = TimelineFilter(kind: EventKind(rawValue: "dog_walk"))

        XCTAssertEqual(filter.clauses, [#"event_kind = "dog_walk""#])
    }

    /// Whatever a kind is called, it is escaped before it reaches PocketBase's
    /// filter parser.
    func testValuesAreEscaped() {
        let filter = TimelineFilter(author: #"u"1"#)

        XCTAssertEqual(filter.clauses, [#"author = "u\"1""#])
    }
}
