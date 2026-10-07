import XCTest
@testable import Peard
import PeardCore
import SwiftUI

/// A connection's own water settings, as `HomeModel` hands them to the quick-send
/// window and the Tallies tab (#322).
///
/// The settings themselves are covered in PeardCore. What needs the app target is
/// the wiring: that the picker is offered this connection's sizes, that progress
/// is measured against this connection's targets, and that turning water off hides
/// both without touching what was logged. Each test gets a shared store of its own
/// (a throwaway suite), so none starts from what another saved.
@MainActor
final class WaterConfigFlowTests: XCTestCase {
    private var app: AppModel!
    private var model: HomeModel!
    private var queue: SendQueue!
    private var storeURL: URL!
    private var sessionStore: KeychainSessionStore!
    private var suite: String!
    private var store: SharedStore!

    private static let pairID = "pair1"
    private let gb = Locale(identifier: "en_GB")

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-waterconfig-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        sessionStore = KeychainSessionStore(service: "peard-waterconfig-test-\(UUID().uuidString)")
        sessionStore.clear()
        suite = "peard-waterconfig-\(UUID().uuidString)"
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

    private var beer: Moment {
        MomentCatalogue.builtin.first { $0.kind == .beer }!
    }

    private func drink(_ ml: Int?) async {
        model.tap(moment: water)
        model.setQuickSendAmount(ml)
        await model.sendNow()
    }

    private func section() -> WaterTodaySection {
        WaterTodaySection(tallies: model.momentTallies, config: model.waterConfig, mineLabel: "You", othersLabel: "Ari")
    }

    // MARK: Defaults

    func testAConnectionThatSetNothingUsesTheBuiltInSizesAndTargets() async {
        model.tap(moment: water)

        XCTAssertEqual(model.waterConfig, .standard)
        XCTAssertEqual(model.quickSendWaterPresets?.map(\.ml), [330, 500])
        XCTAssertEqual(model.waterProgress.minimum, WaterAmount.defaultMinimum)
        XCTAssertEqual(model.waterProgress.recommended, WaterAmount.defaultRecommended)
    }

    // MARK: Presets

    func testThePickerIsOfferedTheConfiguredSizes() {
        model.updateWaterConfig {
            $0.removePreset(500)
            $0.addPreset(250)
            $0.addPreset(750)
        }
        model.tap(moment: water)

        XCTAssertEqual(model.quickSendWaterPresets?.map(\.ml), [330, 250, 750])
        XCTAssertEqual(model.quickSendWaterPresets?.map(\.label), ["330 ml (glass)", "250 ml", "750 ml"])
    }

    func testThereIsNoPickerForAMomentThatTakesNoAmount() {
        model.tap(moment: beer)

        XCTAssertNil(model.quickSendWaterPresets)
    }

    func testTheConfiguredPresetsLogTheirAmount() async {
        model.updateWaterConfig { $0.addPreset(250) }
        model.tap(moment: water)
        model.setQuickSendAmount(model.quickSendWaterPresets?.last?.ml)
        await model.sendNow()

        XCTAssertEqual(model.momentTallies.waterToday, 250)
    }

    func testThePickerRendersWithConfiguredSizes() {
        var config = WaterConfig()
        config.addPreset(250)
        config.addPreset(750)
        let picker = WaterAmountPicker(amount: 250, presets: config.presets) { _ in }

        let image = ImageRenderer(content: picker.frame(width: 360))
        XCTAssertNotNil(image.uiImage, "four sizes and the custom field should lay out")
    }

    // MARK: Targets

    func testProgressIsMeasuredAgainstTheConfiguredTargets() async {
        model.updateWaterConfig {
            $0.setMinimum(800)
            $0.setRecommended(1200)
        }
        await drink(500)
        await drink(500)

        let progress = model.waterProgress
        XCTAssertEqual(progress.stage, .minimumMet)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(progress, locale: gb), "Minimum met · 200 ml to the 1,200 ml goal")

        await drink(500)
        XCTAssertEqual(model.waterProgress.stage, .recommendedMet)
        XCTAssertEqual(MomentBreakdownCopy.waterProgress(model.waterProgress, locale: gb), "Goal met · 1,200 ml")
    }

    func testTargetsAreKeptSeparatelyPerConnection() {
        model.updateWaterConfig { $0.setRecommended(3000) }
        let other = HomeModel(app: app, pairID: "pair2")

        XCTAssertEqual(model.waterConfig.recommended, 3000)
        XCTAssertEqual(other.waterConfig, .standard)
    }

    // MARK: Persistence

    func testSettingsSurviveANewModelForTheSameConnection() {
        model.updateWaterConfig {
            $0.setRecommended(2500)
            $0.addPreset(250)
            $0.isEnabled = false
        }

        let reopened = HomeModel(app: app, pairID: Self.pairID)
        XCTAssertEqual(reopened.waterConfig.recommended, 2500)
        XCTAssertEqual(reopened.waterConfig.presetMLs, [330, 500, 250])
        XCTAssertFalse(reopened.waterConfig.isEnabled)
        XCTAssertEqual(store.waterConfig(forConnection: Self.pairID), reopened.waterConfig)
    }

    // MARK: Disabling

    func testDisablingHidesThePickerAndTheTalliesSection() async {
        await drink(500)
        XCTAssertTrue(section().isShown)

        model.updateWaterConfig { $0.isEnabled = false }
        model.tap(moment: water)

        XCTAssertNil(model.quickSendWaterPresets)
        XCTAssertFalse(section().isShown)
    }

    /// The point of "hide, not delete": what was logged is still there, and
    /// switching water back on brings the section back with the same total.
    func testDisablingKeepsWhatWasLoggedAndEnablingBringsItBack() async {
        model.updateWaterConfig { $0.setRecommended(3000) }
        await drink(330)
        await drink(500)

        model.updateWaterConfig { $0.isEnabled = false }
        XCTAssertEqual(model.momentTallies.waterToday, 830)
        XCTAssertEqual(model.momentTallies.kinds.first { $0.kind == .water }?.mine.day, 2)
        XCTAssertEqual(model.pendingSends.compactMap(\.amount), [330, 500])

        model.updateWaterConfig { $0.isEnabled = true }
        XCTAssertTrue(section().isShown)
        XCTAssertEqual(model.waterConfig.recommended, 3000, "the targets were kept while it was off")
        XCTAssertEqual(model.waterProgress.ml, 830)
    }

    func testWaterStillLogsWithoutAnAmountWhenDisabled() async {
        model.updateWaterConfig { $0.isEnabled = false }
        await drink(nil)

        XCTAssertEqual(model.momentTallies.kinds.first { $0.kind == .water }?.mine.day, 1)
        XCTAssertEqual(model.momentTallies.waterToday, 0)
    }

    func testTheTalliesSectionIsAbsentUntilWaterIsLogged() {
        XCTAssertFalse(section().isShown)
    }

    func testTheSettingsSectionRenders() {
        let settings = WaterSettingsSection(model: model)
        let image = ImageRenderer(content: Form { settings }.frame(width: 360, height: 640))
        XCTAssertNotNil(image.uiImage, "the settings section should lay out")
    }
}
