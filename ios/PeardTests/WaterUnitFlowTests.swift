import XCTest
@testable import Peard
import PeardCore
import SwiftUI

/// Water shown in millilitres or fluid ounces (#324), as the app wires it.
///
/// The conversions themselves are covered in PeardCore (`WaterUnitTests`). What
/// needs the app target is the threading: that the user's choice reaches the
/// picker, the Tallies total and the progress copy, that a figure typed in ounces
/// is stored as millilitres, and that switching the unit never touches a stored
/// amount. Each test gets a shared store of its own (a throwaway suite).
@MainActor
final class WaterUnitFlowTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queue: SendQueue!
    private var storeURL: URL!
    private var sessionStore: KeychainSessionStore!
    private var suite: String!
    private var store: SharedStore!

    private static let pairID = "pair1"
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-waterunit-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        sessionStore = KeychainSessionStore(service: "peard-waterunit-test-\(UUID().uuidString)")
        sessionStore.clear()
        suite = "peard-waterunit-\(UUID().uuidString)"
        store = SharedStore(suiteName: suite)
        app = AppModel(sessionStore: sessionStore, sharedStore: store, sendQueue: queue)
        await app.attachSendQueue()
        model = HomeModel(app: app, pairID: Self.pairID)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        sessionStore?.clear()
        UserDefaults().removePersistentDomain(forName: suite)
        sessionStore = nil
        store = nil
        model = nil
        app = nil
        queue = nil
        try await super.tearDown()
    }

    private var water: Moment {
        Moment(kind: .water, emoji: "💧", label: "Water", origin: .custom(recordID: "rec-water"))
    }

    private func drink(_ ml: Int?) async {
        model.tap(moment: water)
        model.setQuickSendAmount(ml)
        await model.sendNow()
    }

    private func section() -> WaterTodaySection {
        WaterTodaySection(
            tallies: model.momentTallies,
            config: model.waterConfig,
            unit: model.waterUnit,
            mineLabel: "You",
            othersLabel: "Ari"
        )
    }

    // MARK: The preference

    func testTheUnitIsTheUsersAndReachesEveryConnectionsModel() {
        app.waterUnit = .fluidOunces

        XCTAssertEqual(model.waterUnit, .fluidOunces)
        XCTAssertEqual(HomeModel(app: app, pairID: "another").waterUnit, .fluidOunces)
    }

    func testTheChoiceIsKeptInTheSharedStore() {
        app.waterUnit = .fluidOunces
        XCTAssertEqual(store.waterUnit, .fluidOunces)

        app.waterUnit = .millilitres
        XCTAssertEqual(store.waterUnit, .millilitres)
    }

    func testAFreshLaunchReadsTheStoredChoice() {
        store.waterUnit = .fluidOunces
        let relaunched = AppModel(sessionStore: sessionStore, sharedStore: store, sendQueue: queue)

        XCTAssertEqual(relaunched.waterUnit, .fluidOunces)
    }

    // MARK: Picker

    func testThePickerChipsReadInTheChosenUnit() {
        model.tap(moment: water)
        let presets = model.quickSendWaterPresets ?? []

        XCTAssertEqual(presets.map { $0.label(in: .millilitres, locale: gb) }, ["330 ml (glass)", "500 ml (bottle)"])
        XCTAssertEqual(presets.map { $0.label(in: .fluidOunces, locale: us) }, ["11.2 fl oz (glass)", "16.9 fl oz (bottle)"])
        XCTAssertEqual(presets.map(\.ml), [330, 500], "the chips are millilitres underneath")
    }

    func testThePickerRendersInEitherUnit() {
        model.tap(moment: water)
        let presets = model.quickSendWaterPresets ?? []
        for unit in WaterUnit.allCases {
            let picker = WaterAmountPicker(amount: 330, presets: presets, unit: unit) { _ in }
            let image = ImageRenderer(content: picker.frame(width: 360))
            XCTAssertNotNil(image.uiImage, "\(unit.symbol) should lay out")
        }
    }

    func testACustomOunceEntryIsConvertedToMillilitres() {
        XCTAssertEqual(WaterAmountPicker.entry("12", unit: .fluidOunces).ml, 355)
        XCTAssertEqual(WaterAmountPicker.entry("12", unit: .fluidOunces).digits, "12")
        XCTAssertEqual(WaterAmountPicker.entry("12", unit: .millilitres).ml, 12)
    }

    func testTheCustomFieldKeepsOnlyAsManyDigitsAsTheUnitCanUse() {
        XCTAssertEqual(WaterAmountPicker.entry("12345", unit: .millilitres).digits, "1234")
        XCTAssertEqual(WaterAmountPicker.entry("12345", unit: .fluidOunces).digits, "123")
        XCTAssertEqual(WaterAmountPicker.entry("1x2", unit: .fluidOunces).digits, "12")
    }

    func testAnOuncesEntryTooBigToBeAnAmountSelectsNothing() {
        XCTAssertNil(WaterAmountPicker.entry("200", unit: .fluidOunces).ml, "200 fl oz is over five litres")
        XCTAssertNil(WaterAmountPicker.entry("", unit: .fluidOunces).ml)
    }

    func testACustomOunceEntryIsQueuedAndSentAsMillilitres() async throws {
        app.waterUnit = .fluidOunces
        model.tap(moment: water)
        model.setQuickSendAmount(WaterAmountPicker.entry("12", unit: model.waterUnit).ml)
        await model.sendNow()

        let queued = await queue.pending
        XCTAssertEqual(queued.first?.amount, 355)
        XCTAssertEqual(queued.first?.postFields["amount"], "355", "the wire is millilitres, whatever was typed")
        XCTAssertEqual(model.momentTallies.waterToday, 355)
    }

    func testAPresetChosenInOuncesLogsItsMillilitres() async {
        app.waterUnit = .fluidOunces
        model.tap(moment: water)
        model.setQuickSendAmount(model.quickSendWaterPresets?.first?.ml)
        await model.sendNow()

        let queued = await queue.pending
        XCTAssertEqual(queued.first?.amount, 330, "the chip reads 11.2 fl oz and logs 330 ml")
        XCTAssertEqual(queued.first?.postFields["amount"], "330")
    }

    // MARK: Tallies

    func testTheTalliesTotalReadsInTheChosenUnit() async {
        await drink(330)
        await drink(500)
        await drink(500)

        app.waterUnit = .millilitres
        XCTAssertEqual(section().totalLabel(locale: gb), "1,330 ml today")
        app.waterUnit = .fluidOunces
        XCTAssertEqual(section().totalLabel(locale: us), "45 fl oz today")
    }

    func testTheTalliesSectionRendersInEitherUnit() async {
        await drink(330)
        for unit in WaterUnit.allCases {
            app.waterUnit = unit
            let image = ImageRenderer(content: Form { section() }.frame(width: 360, height: 400))
            XCTAssertTrue(section().isShown)
            XCTAssertNotNil(image.uiImage, "\(unit.symbol) should lay out")
        }
    }

    func testProgressCopyReadsInTheChosenUnit() async {
        await drink(500)
        let progress = model.waterProgress

        XCTAssertEqual(
            MomentBreakdownCopy.waterProgress(progress, unit: .millilitres, locale: gb),
            "1,000 ml to the 1,500 ml minimum"
        )
        XCTAssertEqual(
            MomentBreakdownCopy.waterProgress(progress, unit: .fluidOunces, locale: us),
            "33.8 fl oz to the 50.7 fl oz minimum"
        )
    }

    func testTheSplitReadsInTheChosenUnit() {
        XCTAssertEqual(
            MomentBreakdownCopy.waterSplit(
                mine: 830, others: 250, mineLabel: "You", othersLabel: "Ari", unit: .fluidOunces, locale: us
            ),
            "You 28.1 fl oz · Ari 8.5 fl oz"
        )
    }

    // MARK: Settings

    func testTheSettingsSectionRendersInEitherUnit() {
        for unit in WaterUnit.allCases {
            app.waterUnit = unit
            let settings = WaterSettingsSection(model: model)
            let image = ImageRenderer(content: Form { settings }.frame(width: 360, height: 640))
            XCTAssertNotNil(image.uiImage, "\(unit.symbol) should lay out")
        }
    }

    func testTheUnitSwitchRenders() {
        let image = ImageRenderer(content: Form { WaterUnitSection(app: app) }.frame(width: 360, height: 200))
        XCTAssertNotNil(image.uiImage)
    }

    func testANewSizeTypedInOuncesIsStoredAsMillilitres() {
        app.waterUnit = .fluidOunces
        let ml = WaterAmount.parse("12", unit: model.waterUnit)
        model.updateWaterConfig { _ = $0.addPreset(ml ?? 0) }

        XCTAssertEqual(model.waterConfig.presetMLs, [330, 500, 355])
        XCTAssertEqual(store.waterConfig(forConnection: Self.pairID).presetMLs, [330, 500, 355])
        XCTAssertEqual(model.quickSendWaterPresets, nil, "no picker until water is tapped")
    }

    // MARK: Storage never moves

    func testSwitchingUnitLeavesStoredAmountsAndTotalsUntouched() async {
        await drink(330)
        await drink(500)
        model.updateWaterConfig {
            $0.setRecommended(2400)
            $0.addPreset(355)
        }
        let queuedBefore = await queue.pending
        let configBefore = model.waterConfig
        let storedBefore = store.waterConfig(forConnection: Self.pairID)
        let totalBefore = model.momentTallies.waterToday

        app.waterUnit = .fluidOunces
        app.waterUnit = .millilitres
        app.waterUnit = .fluidOunces

        let queuedAfter = await queue.pending
        XCTAssertEqual(queuedAfter, queuedBefore)
        XCTAssertEqual(queuedAfter.map(\.amount), [330, 500])
        XCTAssertEqual(queuedAfter.map { $0.postFields["amount"] }, ["330", "500"])
        XCTAssertEqual(model.momentTallies.waterToday, totalBefore)
        XCTAssertEqual(totalBefore, 830)
        XCTAssertEqual(model.waterConfig, configBefore)
        XCTAssertEqual(store.waterConfig(forConnection: Self.pairID), storedBefore)
        XCTAssertEqual(model.waterProgress.ml, 830)
    }
}
