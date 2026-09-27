import AppIntents
import XCTest
@testable import PeardCore

/// What Siri will accept for each built-in moment.
///
/// Nothing fails when a synonym goes missing — Siri just stops understanding
/// "log a pint" or, worse, "log a Lou", which is what speech-to-text makes of
/// "loo". So the ones that matter are pinned here.
final class SiriVocabularyTests: XCTestCase {
    private func synonyms(_ kind: BuiltinMomentKind) -> [String] {
        let representation = BuiltinMomentKind.caseDisplayRepresentations[kind]
        return (representation?.synonyms ?? []).map { String(localized: $0) }
    }

    func testEveryBuiltinHasATitleAndSynonyms() {
        for kind in BuiltinMomentKind.allCases {
            XCTAssertNotNil(BuiltinMomentKind.caseDisplayRepresentations[kind], "\(kind) has no display representation")
            XCTAssertFalse(synonyms(kind).isEmpty, "\(kind) has no synonyms")
        }
    }

    func testLooAcceptsWhatSpeechToTextHears() {
        XCTAssertTrue(synonyms(.loo).contains("Lou"))
        XCTAssertTrue(synonyms(.loo).contains("Toilet"))
    }

    func testBeerAcceptsAPint() {
        XCTAssertTrue(synonyms(.beer).contains("Pint"))
    }
}
