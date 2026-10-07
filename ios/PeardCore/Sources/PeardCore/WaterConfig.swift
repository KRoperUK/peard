import Foundation

/// One connection's water settings (#322): whether water is tracked there, the
/// two daily targets, and the sizes offered as chips.
///
/// Kept on the device, per connection, in `SharedStore` — the way pins are — not on
/// the server. Nothing here is a fact about a moment: it only decides what this
/// phone offers and how it measures a day. (Gamification, #323, may want targets
/// both people see and so a server-shared copy; that is a decision for then.)
///
/// The invariants — both targets in `step...WaterAmount.maximum`, the minimum no
/// higher than the recommended amount, presets in range, unique and capped — hold
/// however the value is built or decoded, so a stale or hand-edited store cannot
/// hand the UI a target that divides by zero or a bar that overshoots.
public struct WaterConfig: Codable, Equatable, Sendable {
    /// The smallest target, and the step the settings controls move in.
    public static let step = 100
    /// More chips than this and the quick-send window stops fitting on a phone.
    public static let maximumPresets = 4

    /// What a connection has until somebody changes it: tracked, with the built-in
    /// targets and the glass and bottle chips.
    public static let standard = WaterConfig()

    /// When false the connection's water UI is hidden. Nothing is deleted: moments
    /// already logged, with their amounts, stay where they are.
    public var isEnabled: Bool
    public private(set) var minimum: Int
    public private(set) var recommended: Int
    /// Chip sizes in millilitres, in the order they are shown.
    public private(set) var presetMLs: [Int]

    public init(
        isEnabled: Bool = true,
        minimum: Int = WaterAmount.defaultMinimum,
        recommended: Int = WaterAmount.defaultRecommended,
        presetMLs: [Int] = WaterAmount.presets.map(\.ml)
    ) {
        self.isEnabled = isEnabled
        let goal = Self.clampedTarget(recommended, upTo: WaterAmount.maximum)
        self.recommended = goal
        self.minimum = Self.clampedTarget(minimum, upTo: goal)
        self.presetMLs = Self.cleaned(presetMLs)
    }

    /// Fields missing from an older or partial record read as the defaults rather
    /// than failing the whole config.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            minimum: try container.decodeIfPresent(Int.self, forKey: .minimum) ?? WaterAmount.defaultMinimum,
            recommended: try container.decodeIfPresent(Int.self, forKey: .recommended) ?? WaterAmount.defaultRecommended,
            presetMLs: try container.decodeIfPresent([Int].self, forKey: .presetMLs) ?? WaterAmount.presets.map(\.ml)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, minimum, recommended, presetMLs
    }

    // MARK: Targets

    /// Sets the daily minimum, held between `step` and the recommended amount.
    public mutating func setMinimum(_ ml: Int) {
        minimum = Self.clampedTarget(ml, upTo: recommended)
    }

    /// Sets the recommended amount, held between the minimum and the largest
    /// amount a moment can carry.
    public mutating func setRecommended(_ ml: Int) {
        recommended = min(max(ml, minimum), WaterAmount.maximum)
    }

    /// Today's `ml` measured against these targets.
    public func progress(ml: Int) -> WaterProgress {
        WaterProgress(ml: ml, minimum: minimum, recommended: recommended)
    }

    private static func clampedTarget(_ ml: Int, upTo ceiling: Int) -> Int {
        min(max(ml, step), max(ceiling, step))
    }

    // MARK: Presets

    /// The chips, as `WaterAmountPicker` draws them.
    public var presets: [WaterAmount.Preset] { presetMLs.map(WaterAmount.preset(ml:)) }

    /// Whether another chip can be added.
    public var canAddPreset: Bool { presetMLs.count < Self.maximumPresets }

    /// Adds a chip. False, and nothing changed, when the size is out of range, is
    /// there already, or the row is full.
    @discardableResult
    public mutating func addPreset(_ ml: Int) -> Bool {
        guard canAddPreset, let ml = WaterAmount.normalised(ml), !presetMLs.contains(ml) else { return false }
        presetMLs.append(ml)
        return true
    }

    public mutating func removePreset(_ ml: Int) {
        presetMLs.removeAll { $0 == ml }
    }

    /// In range, first occurrence only, and no more than fit.
    private static func cleaned(_ sizes: [Int]) -> [Int] {
        var seen = Set<Int>()
        let kept = sizes.compactMap(WaterAmount.normalised).filter { seen.insert($0).inserted }
        return Array(kept.prefix(maximumPresets))
    }
}
