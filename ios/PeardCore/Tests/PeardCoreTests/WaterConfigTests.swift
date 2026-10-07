import XCTest
@testable import PeardCore

/// A connection's own water settings (#322).
final class WaterConfigTests: XCTestCase {
    private func makeStore() -> (SharedStore, UserDefaults?) {
        let suite = "water-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (SharedStore(defaults: defaults), defaults)
    }

    // MARK: Defaults

    func testTheStandardConfigIsTheBuiltInDefaults() {
        let config = WaterConfig.standard

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.minimum, WaterAmount.defaultMinimum)
        XCTAssertEqual(config.recommended, WaterAmount.defaultRecommended)
        XCTAssertEqual(config.presets, WaterAmount.presets)
        XCTAssertEqual(config.presets.map(\.label), ["330 ml (glass)", "500 ml (bottle)"])
    }

    func testAConnectionThatSetNothingReadsTheStandardConfig() {
        let (store, _) = makeStore()

        XCTAssertEqual(store.waterConfig(forConnection: "never-seen"), .standard)
    }

    func testAnUnreadableRecordFallsBackToTheStandardConfig() {
        let (store, defaults) = makeStore()
        defaults?.set(["pair": Data("not json".utf8)], forKey: SharedStore.Key.waterConfigs)

        XCTAssertEqual(store.waterConfig(forConnection: "pair"), .standard)
    }

    // MARK: Storage

    func testAConfigRoundTripsPerConnection() {
        let (store, _) = makeStore()
        var flat = WaterConfig()
        flat.setRecommended(2500)
        flat.setMinimum(1800)
        flat.removePreset(500)
        flat.addPreset(250)
        var pair = WaterConfig(isEnabled: false)
        pair.setMinimum(1000)

        store.setWaterConfig(flat, forConnection: "flat")
        store.setWaterConfig(pair, forConnection: "pair")

        XCTAssertEqual(store.waterConfig(forConnection: "flat"), flat)
        XCTAssertEqual(store.waterConfig(forConnection: "flat").presetMLs, [330, 250])
        XCTAssertEqual(store.waterConfig(forConnection: "pair"), pair)
        XCTAssertFalse(store.waterConfig(forConnection: "pair").isEnabled)
        XCTAssertEqual(store.waterConfig(forConnection: "other"), .standard)
    }

    func testStoringTheStandardConfigForgetsTheRecord() {
        let (store, defaults) = makeStore()
        store.setWaterConfig(WaterConfig(minimum: 1000), forConnection: "pair")
        store.setWaterConfig(.standard, forConnection: "pair")

        XCTAssertEqual(store.waterConfig(forConnection: "pair"), .standard)
        let stored = defaults?.dictionary(forKey: SharedStore.Key.waterConfigs) as? [String: Data]
        XCTAssertNil(stored?["pair"])
    }

    func testAMissingFieldReadsAsItsDefault() throws {
        let config = try JSONDecoder().decode(WaterConfig.self, from: Data(#"{"isEnabled":false,"recommended":2500}"#.utf8))

        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.recommended, 2500)
        XCTAssertEqual(config.minimum, WaterAmount.defaultMinimum)
        XCTAssertEqual(config.presetMLs, [330, 500])
    }

    // MARK: Validation

    func testTheMinimumIsClampedToTheRecommendedAmount() {
        var config = WaterConfig()
        config.setMinimum(9000)
        XCTAssertEqual(config.minimum, WaterAmount.defaultRecommended)

        let built = WaterConfig(minimum: 3000, recommended: 2000)
        XCTAssertEqual(built.minimum, 2000)
        XCTAssertEqual(built.recommended, 2000)
    }

    func testTheRecommendedAmountCannotFallBelowTheMinimum() {
        var config = WaterConfig(minimum: 1500, recommended: 2000)
        config.setRecommended(500)

        XCTAssertEqual(config.recommended, 1500)
        XCTAssertEqual(config.minimum, 1500)
    }

    func testTargetsStayWithinTheLargestAmountAMomentCanCarry() {
        var config = WaterConfig()
        config.setRecommended(WaterAmount.maximum + 1)
        XCTAssertEqual(config.recommended, WaterAmount.maximum)

        XCTAssertEqual(WaterConfig(minimum: -5, recommended: 0).recommended, WaterConfig.step)
        XCTAssertEqual(WaterConfig(minimum: -5, recommended: 0).minimum, WaterConfig.step)
        XCTAssertEqual(WaterConfig(recommended: 99_999).recommended, WaterAmount.maximum)
    }

    func testAStoredConfigThatBreaksTheRulesIsRepairedOnRead() throws {
        let (store, defaults) = makeStore()
        let broken = Data(#"{"isEnabled":true,"minimum":4000,"recommended":1000,"presetMLs":[0,330,330,9999]}"#.utf8)
        defaults?.set(["pair": broken], forKey: SharedStore.Key.waterConfigs)

        let config = store.waterConfig(forConnection: "pair")
        XCTAssertEqual(config.recommended, 1000)
        XCTAssertEqual(config.minimum, 1000)
        XCTAssertEqual(config.presetMLs, [330])
    }

    func testPresetsAreRangeCheckedUniqueAndCapped() {
        var config = WaterConfig(presetMLs: [])
        XCTAssertTrue(config.presets.isEmpty)

        XCTAssertFalse(config.addPreset(0))
        XCTAssertFalse(config.addPreset(WaterAmount.maximum + 1))
        XCTAssertTrue(config.addPreset(250))
        XCTAssertFalse(config.addPreset(250), "a size already offered is not added twice")
        XCTAssertTrue(config.addPreset(400))
        XCTAssertTrue(config.addPreset(750))
        XCTAssertTrue(config.addPreset(1000))
        XCTAssertFalse(config.canAddPreset)
        XCTAssertFalse(config.addPreset(1500), "a fifth chip does not fit")
        XCTAssertEqual(config.presetMLs, [250, 400, 750, 1000])

        config.removePreset(400)
        XCTAssertEqual(config.presetMLs, [250, 750, 1000])
        XCTAssertTrue(config.canAddPreset)
    }

    func testOnlyTheBuiltInSizesHaveNames() {
        let config = WaterConfig(presetMLs: [330, 250])

        XCTAssertEqual(config.presets.map(\.label), ["330 ml (glass)", "250 ml"])
    }

    // MARK: Progress

    func testProgressUsesTheConfiguredTargets() {
        let config = WaterConfig(minimum: 1000, recommended: 1200)

        XCTAssertEqual(config.progress(ml: 1000).stage, .minimumMet)
        XCTAssertEqual(config.progress(ml: 1200).stage, .recommendedMet)
        XCTAssertEqual(WaterConfig.standard.progress(ml: 1000).stage, .underMinimum)
    }
}
