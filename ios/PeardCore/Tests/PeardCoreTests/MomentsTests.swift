import XCTest
@testable import PeardCore

/// The moment catalogue, slug conversion, emoji handling and the quick-send
/// countdown are all pure, so they are covered here rather than on a simulator.
final class MomentsTests: XCTestCase {
    private func kind(
        _ slug: String,
        emoji: String = "🎉",
        label: String = "Party",
        id: String? = nil,
        createdOffset: TimeInterval = 0
    ) -> MomentKind {
        MomentKind(
            id: id ?? "id-\(slug)",
            pair: "pair1",
            slug: EventKind(rawValue: slug),
            emoji: emoji,
            label: label,
            createdBy: "user1",
            created: Date(timeIntervalSince1970: 1_700_000_000 + createdOffset)
        )
    }

    // MARK: Catalogue

    func testBuiltinMomentsAreAvailableWithoutAnyCustomKinds() {
        let available = MomentCatalogue.available(customKinds: [])
        XCTAssertEqual(available.map(\.kind.rawValue), ["beer", "loo", "coffee"])
        XCTAssertEqual(available.map(\.emoji), ["🍺", "💩", "☕"])
        XCTAssertEqual(available.map(\.label), ["Beer", "Loo", "Coffee"])
        XCTAssertTrue(available.allSatisfy { $0.origin == .builtin })
        XCTAssertFalse(available.contains { $0.needsPublishing })

        XCTAssertEqual(MomentCatalogue.emoji(for: .loo), "💩")
        XCTAssertEqual(MomentCatalogue.label(for: .coffee), "Coffee")
    }

    func testCustomKindsFollowTheBuiltinsInCreationOrder() {
        let available = MomentCatalogue.available(customKinds: [
            kind("gym", emoji: "🏋️", label: "Gym", createdOffset: 20),
            kind("tea", emoji: "🫖", label: "Tea", createdOffset: 10),
        ])
        XCTAssertEqual(available.map(\.kind.rawValue), ["beer", "loo", "coffee", "tea", "gym"])
        XCTAssertEqual(available.last?.emoji, "🏋️")
        XCTAssertEqual(MomentCatalogue.descriptor(for: "tea", customKinds: [kind("tea")])?.origin, .custom(recordID: "id-tea"))
    }

    func testACustomKindReplacesABuiltinWithTheSameSlug() {
        let custom = kind("loo", emoji: "🚽", label: "Bathroom")
        let available = MomentCatalogue.available(customKinds: [custom])

        XCTAssertEqual(available.count, 3, "re-labelling a built-in must not duplicate it")
        let loo = available.first { $0.kind == .loo }
        XCTAssertEqual(loo?.emoji, "🚽")
        XCTAssertEqual(loo?.label, "Bathroom")
    }

    func testUnusedPresetsExcludeBuiltinsAndAlreadyPublishedKinds() {
        let unused = MomentCatalogue.unusedPresets(customKinds: [kind("tea")])
        let slugs = unused.map(\.kind.rawValue)

        XCTAssertFalse(slugs.contains("tea"), "already published")
        XCTAssertFalse(slugs.contains("beer"), "built in")
        XCTAssertTrue(slugs.contains("gym"))
        XCTAssertTrue(unused.allSatisfy { $0.needsPublishing })
    }

    func testEmojiAndLabelFallBackForAnUnknownKind() {
        XCTAssertEqual(MomentCatalogue.emoji(for: EventKind(rawValue: "kombucha")), "🍐")
        XCTAssertEqual(MomentCatalogue.label(for: EventKind(rawValue: "kombucha")), "Kombucha")
        XCTAssertEqual(MomentCatalogue.emoji(for: nil), "🍐")
        XCTAssertEqual(MomentCatalogue.label(for: nil), "")
    }

    func testCustomKindResolvesEvenWhenItsEmojiOrLabelIsBlank() {
        let blank = kind("late_night", emoji: "", label: "")
        XCTAssertEqual(MomentCatalogue.emoji(for: "late_night", customKinds: [blank]), "🍐")
        XCTAssertEqual(MomentCatalogue.label(for: "late_night", customKinds: [blank]), "Late night")
    }

    func testPhotoPostsUseTheCameraEmojiRegardlessOfKind() {
        let photo = Post(
            id: "p1", pair: "pair1", author: "user1", type: .photo,
            eventKind: .beer, media: "shot.jpg", created: Date()
        )
        XCTAssertEqual(MomentCatalogue.emoji(for: photo), "📸")
    }

    func testPresetSlugsAreUniqueAndDoNotCollideWithBuiltins() {
        let builtinSlugs = Set(MomentCatalogue.builtin.map(\.kind.rawValue))
        let presetSlugs = MomentCatalogue.presets.map(\.kind.rawValue)

        XCTAssertEqual(Set(presetSlugs).count, presetSlugs.count, "duplicate preset slug")
        XCTAssertTrue(builtinSlugs.isDisjoint(with: Set(presetSlugs)))
        // Every preset must survive the same slug rules a typed label goes
        // through, or tapping it would write a different kind than it displays.
        for preset in MomentCatalogue.presets {
            XCTAssertEqual(MomentSlug.make(from: preset.kind.rawValue), preset.kind.rawValue)
            XCTAssertLessThanOrEqual(preset.kind.rawValue.count, MomentSlug.maxLength)
        }
    }

    // MARK: Slugs

    func testSlugLowercasesAndJoinsWordsWithUnderscores() {
        XCTAssertEqual(MomentSlug.make(from: "Thinking of you"), "thinking_of_you")
        XCTAssertEqual(MomentSlug.make(from: "Dog walk"), "dog_walk")
        XCTAssertEqual(MomentSlug.make(from: "  Gym   "), "gym")
    }

    func testSlugStripsEmojiPunctuationAndDiacritics() {
        XCTAssertEqual(MomentSlug.make(from: "Café ☕"), "cafe")
        XCTAssertEqual(MomentSlug.make(from: "Dog-walk!"), "dog_walk")
        XCTAssertEqual(MomentSlug.make(from: "5 a side"), "5_a_side")
    }

    func testSlugFallsBackWhenALabelHasNoSlugSafeCharacters() {
        XCTAssertEqual(MomentSlug.make(from: "🎉🎉"), MomentSlug.fallback)
        XCTAssertEqual(MomentSlug.make(from: ""), MomentSlug.fallback)
        XCTAssertEqual(MomentSlug.make(from: "···"), MomentSlug.fallback)
    }

    func testSlugIsBoundedByTheServerColumnWidth() {
        let slug = MomentSlug.make(from: String(repeating: "long ", count: 40))
        XCTAssertLessThanOrEqual(slug.count, MomentSlug.maxLength)
        XCTAssertFalse(slug.hasSuffix("_"), "a truncated slug must not end mid-separator")
    }

    func testHumanisedTurnsASlugBackIntoASentence() {
        XCTAssertEqual(MomentSlug.humanised("thinking_of_you"), "Thinking of you")
        XCTAssertEqual(MomentSlug.humanised("gym"), "Gym")
    }

    // MARK: Emoji

    func testFirstEmojiPicksASingleGlyphOutOfMixedText() {
        XCTAssertEqual(MomentEmoji.first(in: "🍺"), "🍺")
        XCTAssertEqual(MomentEmoji.first(in: "a🍺b🎉"), "🍺")
        XCTAssertEqual(MomentEmoji.first(in: "❤️"), "❤️", "variation-selector emoji")
        XCTAssertEqual(MomentEmoji.first(in: "🏋️"), "🏋️")
        XCTAssertNil(MomentEmoji.first(in: "beer"))
        XCTAssertNil(MomentEmoji.first(in: ""))
    }

    func testEveryOfferedEmojiIsRecognisedAsEmoji() {
        for suggestion in MomentEmoji.suggestions {
            let characters = Array(suggestion)
            XCTAssertEqual(characters.count, 1, "\(suggestion) is not a single grapheme")
            XCTAssertTrue(MomentEmoji.isEmoji(characters[0]), "\(suggestion) not detected as emoji")
            XCTAssertEqual(MomentEmoji.first(in: suggestion), suggestion)
        }
        XCTAssertEqual(Set(MomentEmoji.suggestions).count, MomentEmoji.suggestions.count, "duplicate suggestion")
    }

    // MARK: Quick send

    func testCountdownStartsAtTheFullWindowAndRunsDown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: start)

        XCTAssertEqual(send.secondsRemaining(now: start), 3)
        XCTAssertEqual(send.secondsRemaining(now: start.addingTimeInterval(0.5)), 3)
        XCTAssertEqual(send.secondsRemaining(now: start.addingTimeInterval(1.2)), 2)
        XCTAssertEqual(send.secondsRemaining(now: start.addingTimeInterval(2.2)), 1)
        XCTAssertEqual(send.secondsRemaining(now: start.addingTimeInterval(3.0)), 0)
        XCTAssertEqual(send.secondsRemaining(now: start.addingTimeInterval(9.0)), 0)
    }

    func testSendFiresOnlyOnceTheWindowHasElapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        let send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: start)

        XCTAssertFalse(send.shouldSend(now: start))
        XCTAssertFalse(send.shouldSend(now: start.addingTimeInterval(2.99)))
        XCTAssertTrue(send.shouldSend(now: start.addingTimeInterval(3.0)))
    }

    func testTypingANoteHoldsTheSendIndefinitely() {
        let start = Date(timeIntervalSince1970: 1_000)
        let held = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: start, isHeld: true)

        XCTAssertFalse(held.shouldSend(now: start.addingTimeInterval(60)))
        XCTAssertEqual(held.secondsRemaining(now: start.addingTimeInterval(60)), 3)
        XCTAssertEqual(held.progressRemaining(now: start.addingTimeInterval(60)), 1)
        XCTAssertEqual(held.caption(now: start.addingTimeInterval(60)), "Tap send when ready")
    }

    func testProgressRunsFromOneToZeroAcrossTheWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: start)

        XCTAssertEqual(send.progressRemaining(now: start), 1, accuracy: 0.001)
        XCTAssertEqual(send.progressRemaining(now: start.addingTimeInterval(1.5)), 0.5, accuracy: 0.001)
        XCTAssertEqual(send.progressRemaining(now: start.addingTimeInterval(3)), 0, accuracy: 0.001)
        XCTAssertEqual(send.progressRemaining(now: start.addingTimeInterval(4)), 0, accuracy: 0.001)
    }

    func testCaptionCountsDownThenReportsSending() {
        let start = Date(timeIntervalSince1970: 1_000)
        let send = QuickSend(moment: MomentCatalogue.builtin[0], startedAt: start)

        XCTAssertEqual(send.caption(now: start), "Sending in 3…")
        XCTAssertEqual(send.caption(now: start.addingTimeInterval(2.2)), "Sending in 1…")
        XCTAssertEqual(send.caption(now: start.addingTimeInterval(3.1)), "Sending…")
    }
}
