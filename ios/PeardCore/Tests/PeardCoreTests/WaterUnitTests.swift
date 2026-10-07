import XCTest
@testable import PeardCore

/// Millilitres or fluid ounces, for display only (#324). Millilitres stays the one
/// stored and sent unit; everything here is the conversion at the edge.
final class WaterUnitTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    private func makeStore() -> (SharedStore, UserDefaults?) {
        let suite = "water-unit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (SharedStore(defaults: defaults), defaults)
    }

    // MARK: Default from the locale

    func testTheUSReadsInFluidOuncesAndEveryoneElseInMillilitres() {
        XCTAssertEqual(WaterUnit.default(for: us), .fluidOunces)
        for identifier in ["en_GB", "de_DE", "fr_FR", "en_CA", "en_AU", "ja_JP", "en"] {
            XCTAssertEqual(WaterUnit.default(for: Locale(identifier: identifier)), .millilitres, identifier)
        }
    }

    func testNothingStoredFollowsTheLocale() {
        XCTAssertEqual(WaterUnit(storedValue: nil, locale: us), .fluidOunces)
        XCTAssertEqual(WaterUnit(storedValue: nil, locale: gb), .millilitres)
        XCTAssertEqual(WaterUnit(storedValue: "gallons", locale: us), .fluidOunces, "unknown falls back, never fails")
    }

    func testAChoiceBeatsTheLocale() {
        XCTAssertEqual(WaterUnit(storedValue: "ml", locale: us), .millilitres)
        XCTAssertEqual(WaterUnit(storedValue: "floz", locale: gb), .fluidOunces)
    }

    // MARK: Conversion

    func testMillilitresDisplayAsThemselves() {
        XCTAssertEqual(WaterUnit.millilitres.displayed(ml: 330), 330)
        XCTAssertEqual(WaterUnit.millilitres.ml(fromDisplayed: 330), 330)
    }

    func testMillilitresToFluidOuncesRoundsToATenth() {
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: 330), 11.2)
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: 500), 16.9)
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: 1330), 45.0)
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: 0), 0)
    }

    func testFluidOuncesToMillilitresRoundsToTheNearest() {
        XCTAssertEqual(WaterUnit.fluidOunces.ml(fromDisplayed: 8), 237)
        XCTAssertEqual(WaterUnit.fluidOunces.ml(fromDisplayed: 12), 355)
        XCTAssertEqual(WaterUnit.fluidOunces.ml(fromDisplayed: 16), 473)
        XCTAssertEqual(WaterUnit.fluidOunces.ml(fromDisplayed: 1), 30)
    }

    func testAWholeOunceReadsBackAsTheSameOunce() {
        for ounces in 1...169 {
            let ml = WaterUnit.fluidOunces.ml(fromDisplayed: Double(ounces))
            XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: ml), Double(ounces), "\(ounces) fl oz = \(ml) ml")
        }
    }

    func testAnyAmountSurvivesTheTripThroughOuncesToWithinRounding() {
        // A tenth of an ounce is about 3 ml, so a displayed-then-typed figure is
        // at most half that from where it started.
        for ml in 1...WaterAmount.maximum {
            let shown = WaterUnit.fluidOunces.displayed(ml: ml)
            let back = WaterUnit.fluidOunces.ml(fromDisplayed: shown)
            XCTAssertLessThanOrEqual(abs(back - ml), 2, "\(ml) ml -> \(shown) fl oz -> \(back) ml")
        }
    }

    // MARK: Formatting

    func testLabelsStayInMillilitresByDefault() {
        XCTAssertEqual(WaterAmount.label(1330, locale: gb), "1,330 ml")
        XCTAssertEqual(WaterAmount.label(1330, unit: .millilitres, locale: gb), "1,330 ml")
        XCTAssertEqual(WaterAmount.todayLabel(1330, unit: .millilitres, locale: gb), "1,330 ml today")
    }

    func testLabelsInFluidOuncesDropATrailingZero() {
        XCTAssertEqual(WaterAmount.label(330, unit: .fluidOunces, locale: us), "11.2 fl oz")
        XCTAssertEqual(WaterAmount.label(1330, unit: .fluidOunces, locale: us), "45 fl oz")
        XCTAssertEqual(WaterAmount.label(2000, unit: .fluidOunces, locale: us), "67.6 fl oz")
        XCTAssertEqual(WaterAmount.todayLabel(1330, unit: .fluidOunces, locale: us), "45 fl oz today")
    }

    func testOuncesFollowTheReadersDecimalSeparator() {
        XCTAssertEqual(WaterAmount.label(330, unit: .fluidOunces, locale: Locale(identifier: "de_DE")), "11,2 fl oz")
    }

    func testPresetChipsKeepTheirNamesInEitherUnit() {
        XCTAssertEqual(WaterAmount.glass.label(in: .millilitres, locale: gb), "330 ml (glass)")
        XCTAssertEqual(WaterAmount.glass.label(in: .fluidOunces, locale: us), "11.2 fl oz (glass)")
        XCTAssertEqual(WaterAmount.bottle.label(in: .fluidOunces, locale: us), "16.9 fl oz (bottle)")
        XCTAssertEqual(WaterAmount.preset(ml: 355).label(in: .fluidOunces, locale: us), "12 fl oz")
        XCTAssertEqual(WaterAmount.glass.label, "330 ml (glass)", "the plain label is still millilitres")
    }

    func testTheFigureAloneHasNoUnit() {
        XCTAssertEqual(WaterAmount.number(1330, locale: gb), "1,330")
        XCTAssertEqual(WaterAmount.number(1330, unit: .fluidOunces, locale: us), "45")
    }

    // MARK: Parsing a typed size back to millilitres

    func testATypedMillilitreSizeParsesAsBefore() {
        XCTAssertEqual(WaterAmount.parse("250", unit: .millilitres), 250)
        XCTAssertNil(WaterAmount.parse("5001", unit: .millilitres))
    }

    func testATypedOunceSizeBecomesMillilitres() {
        XCTAssertEqual(WaterAmount.parse("12", unit: .fluidOunces), 355)
        XCTAssertEqual(WaterAmount.parse("  8 ", unit: .fluidOunces), 237)
        XCTAssertEqual(WaterAmount.parse("169", unit: .fluidOunces), 4998)
    }

    func testAnOunceSizeThatIsNotAWholeInRangeNumberIsRefused() {
        for bad in ["", "abc", "1.5", "-3", "0", "12oz", "170", "٣", "1,0"] {
            XCTAssertNil(WaterAmount.parse(bad, unit: .fluidOunces), "\"\(bad)\" is not a size")
        }
    }

    func testAnOunceEntryPutsMillilitresOnTheWire() throws {
        let ml = try XCTUnwrap(WaterAmount.parse("12", unit: .fluidOunces))
        var send = QuickSend(moment: Moment(kind: .water, emoji: "💧", label: "Water", origin: .preset))
        send.setAmount(ml)

        XCTAssertEqual(send.amount, 355)
        let pending = PendingSend(
            id: "w", pairID: "p", authorID: "me", kind: .water, emoji: "💧", label: "Water",
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000), amount: send.amount
        )
        XCTAssertEqual(pending.postFields["amount"], "355", "the wire is millilitres, never ounces")
    }

    // MARK: Stepping

    func testMillilitresStepByAHundred() {
        XCTAssertEqual(WaterUnit.millilitres.stepped(1500, up: true), 1600)
        XCTAssertEqual(WaterUnit.millilitres.stepped(1500, up: false), 1400)
    }

    func testOuncesStepAlongMultiplesOfFour() {
        // 1500 ml is 50.7 fl oz: the next stops are 52 and 48 fl oz.
        XCTAssertEqual(WaterUnit.fluidOunces.stepped(1500, up: true), WaterUnit.fluidOunces.ml(fromDisplayed: 52))
        XCTAssertEqual(WaterUnit.fluidOunces.stepped(1500, up: false), WaterUnit.fluidOunces.ml(fromDisplayed: 48))
    }

    func testOunceSteppingFromAStopMovesToTheNextStop() {
        let fifty2 = WaterUnit.fluidOunces.ml(fromDisplayed: 52)
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: WaterUnit.fluidOunces.stepped(fifty2, up: true)), 56)
        XCTAssertEqual(WaterUnit.fluidOunces.displayed(ml: WaterUnit.fluidOunces.stepped(fifty2, up: false)), 48)
    }

    // MARK: The preference

    func testTheUnitIsStoredAndReadBack() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.waterUnit(locale: us), .fluidOunces)
        XCTAssertEqual(store.waterUnit(locale: gb), .millilitres)

        store.waterUnit = .fluidOunces
        XCTAssertEqual(store.waterUnit(locale: gb), .fluidOunces, "a choice beats the locale")
        store.waterUnit = .millilitres
        XCTAssertEqual(store.waterUnit(locale: us), .millilitres)
    }

    func testTheUnitIsTheUsersNotAConnections() {
        let (store, _) = makeStore()
        store.waterUnit = .fluidOunces

        XCTAssertEqual(store.waterConfig(forConnection: "a"), .standard)
        XCTAssertEqual(store.waterConfig(forConnection: "b"), .standard)
    }

    func testSwitchingUnitLeavesTheStoredConfigUntouched() throws {
        let (store, defaults) = makeStore()
        var config = WaterConfig()
        config.setRecommended(2400)
        config.addPreset(355)
        store.setWaterConfig(config, forConnection: "pair")
        let before = defaults?.dictionary(forKey: SharedStore.Key.waterConfigs) as? [String: Data]

        store.waterUnit = .fluidOunces
        store.waterUnit = .millilitres
        store.waterUnit = .fluidOunces

        let after = defaults?.dictionary(forKey: SharedStore.Key.waterConfigs) as? [String: Data]
        XCTAssertEqual(before, after, "targets and chips are millilitres whichever unit is showing")
        XCTAssertEqual(store.waterConfig(forConnection: "pair").recommended, 2400)
        XCTAssertEqual(store.waterConfig(forConnection: "pair").presetMLs, [330, 500, 355])
    }

    func testDisplayingInOuncesDoesNotChangeATotal() {
        let total = 1330
        _ = WaterAmount.label(total, unit: .fluidOunces, locale: us)
        XCTAssertEqual(total, 1330)
        XCTAssertEqual(WaterAmount.label(total, unit: .millilitres, locale: us), "1,330 ml")
    }
}
