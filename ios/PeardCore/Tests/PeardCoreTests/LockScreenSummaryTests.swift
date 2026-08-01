import XCTest
@testable import PeardCore

/// What survives when the widget is one line next to a clock.
final class LockScreenSummaryTests: XCTestCase {
    private func summary(
        state: FeedState = .ok,
        partnerName: String = "Sam",
        groupName: String? = nil,
        emoji: String = "☕",
        momentLabel: String = "Coffee",
        note: String = "",
        tallies: [WidgetFeed.Tally] = [],
        created: Date? = nil
    ) -> LockScreenSummary {
        LockScreenSummary(
            state: state,
            partnerName: partnerName,
            groupName: groupName,
            emoji: emoji,
            momentLabel: momentLabel,
            note: note,
            tallies: tallies,
            created: created
        )
    }

    // MARK: The detail line

    /// The note beats the label. The label is derivable from the emoji beside
    /// it; the note is the part nobody could have guessed.
    func testTheNoteWinsOverTheLabel() {
        XCTAssertEqual(summary(note: "second one, don't judge").detail, "second one, don't judge")
    }

    func testWithoutANoteTheLabelIsUsed() {
        XCTAssertEqual(summary(note: "").detail, "Coffee")
    }

    /// A note of spaces is not a note, and would leave a line that looks like a
    /// rendering fault rather than an empty one.
    func testAWhitespaceNoteIsNotANote() {
        XCTAssertEqual(summary(note: "   \n ").detail, "Coffee")
    }

    /// A moment kind the connection never published resolves to an empty label,
    /// and there is nothing to say beyond the emoji.
    func testWithNeitherNoteNorLabelThereIsNoDetail() {
        XCTAssertNil(summary(momentLabel: "", note: "").detail)
    }

    // MARK: The headline

    func testAOneToOneHeadlineIsJustTheName() {
        XCTAssertEqual(summary().headline, "Sam")
    }

    /// Two connections can both contain a Sam, so a group is named as well.
    func testAGroupIsNamedAlongsideThePerson() {
        XCTAssertEqual(summary(groupName: "Flatmates").headline, "Sam · Flatmates")
    }

    /// A member the server could not resolve still needs a subject.
    func testAnUnnamedPartnerFallsBack() {
        XCTAssertEqual(summary(partnerName: "").headline, PartnerLabel.fallback)
    }

    // MARK: Tallies

    func testTalliesAreJoinedForDisplay() {
        let result = summary(tallies: [
            .init(kind: .coffee, emoji: "☕", label: "Coffee", count: 3),
            .init(kind: .beer, emoji: "🍺", label: "Beer", count: 1),
        ])

        XCTAssertEqual(result.talliesText, "☕ 3  🍺 1")
        XCTAssertEqual(result.todayTotal, 4)
    }

    /// Rectangular is narrower than the small home-screen family, so three is a
    /// ceiling rather than a target.
    func testOnlyThreeTalliesAreShown() {
        let result = summary(tallies: (1...5).map {
            .init(kind: EventKind(rawValue: "k\($0)"), emoji: "🍐", label: "K\($0)", count: $0)
        })

        XCTAssertEqual(result.talliesText?.components(separatedBy: "  ").count, 3)
    }

    /// The total counts every kind, not only the three with room to be drawn —
    /// the circular family shows this number and nothing else, so a cap there
    /// would be a wrong answer rather than a short one.
    func testTheTotalCountsTalliesThatAreNotShown() {
        let result = summary(tallies: (1...5).map {
            .init(kind: EventKind(rawValue: "k\($0)"), emoji: "🍐", label: "K\($0)", count: 1)
        })

        XCTAssertEqual(result.todayTotal, 5)
    }

    func testNoTalliesMeansNoRow() {
        XCTAssertNil(summary().talliesText)
        XCTAssertEqual(summary().todayTotal, 0)
    }

    // MARK: Inline

    /// Inline shares its line with the date and iOS truncates the middle of an
    /// over-long string, so the timestamp is dropped rather than allowed to push
    /// the name out.
    func testTheInlineLineNamesThePersonAndWhatTheySaid() {
        XCTAssertEqual(
            summary(note: "second one").inlineText,
            "☕ Sam · second one"
        )
    }

    func testTheInlineLineFallsBackToTheLabel() {
        XCTAssertEqual(summary(note: "").inlineText, "☕ Sam · Coffee")
    }

    func testTheInlineLineDropsTheSeparatorWithNothingToSay() {
        XCTAssertEqual(summary(momentLabel: "", note: "").inlineText, "☕ Sam")
    }

    /// The group name is not repeated inline — there is not room, and the
    /// headline that carries it is a different family.
    func testTheInlineLineOmitsTheGroup() {
        XCTAssertEqual(summary(groupName: "Flatmates", note: "hi").inlineText, "☕ Sam · hi")
    }

    // MARK: States with nothing to report

    func testAnUnpairedWidgetPromptsInsteadOfReporting() {
        let result = summary(state: .unpaired)

        XCTAssertTrue(result.isPrompt)
        XCTAssertEqual(result.emoji, "🍐")
        XCTAssertEqual(result.inlineText, "🍐 Pear up to get started")
        XCTAssertNil(result.at)
    }

    func testAnEmptyConnectionSaysWhoItIsWaitingOn() {
        let result = summary(state: .empty, partnerName: "Sam")

        XCTAssertTrue(result.isPrompt)
        XCTAssertEqual(result.headline, "Sam")
        XCTAssertEqual(result.inlineText, "🍐 Nothing from Sam yet")
    }

    /// A prompt still reports the day's counts. The state describes the latest
    /// moment, not the tallies, and the circular family is only ever showing the
    /// number.
    func testAPromptStillCarriesTheTotal() {
        let result = summary(state: .empty, tallies: [
            .init(kind: .beer, emoji: "🍺", label: "Beer", count: 2),
        ])

        XCTAssertEqual(result.todayTotal, 2)
    }

    // MARK: Timestamps

    func testTheTimestampIsCarriedThrough() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(summary(created: when).at, when)
    }

    /// A missing emoji would render as a gap where the whole design puts its
    /// only picture.
    func testAMissingEmojiFallsBackToThePear() {
        XCTAssertEqual(summary(emoji: "").emoji, MomentCatalogue.fallbackEmoji)
    }
}
