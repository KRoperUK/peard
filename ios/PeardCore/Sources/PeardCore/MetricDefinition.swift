import Foundation

/// A trackable daily-progress metric: a moment kind whose `amount` counts toward
/// a daily goal (#386).
///
/// Water is the built-in hero; steps, exercise minutes and the like are the same
/// shape with a different unit, goal and label. A definition is everything the
/// UI and the goal maths need that is NOT the connection's own per-member target
/// (that lives on the server, as water's does) — the slug it shares with
/// `EventKind`, how it is drawn, the unit it is measured in, the built-in
/// defaults, and the ceiling one entry may carry.
///
/// Built-ins live in `MetricCatalogue`. A connection's custom metric is a
/// `MomentKind` row that tracks an amount, resolved to a definition the same way
/// a custom moment resolves to a `Moment`.
public struct MetricDefinition: Equatable, Sendable, Identifiable {
    public let slug: EventKind
    public let label: String
    public let emoji: String
    public let unit: MetricUnit
    public let defaultMinimum: Int
    public let defaultGoal: Int
    /// The largest amount one entry may carry; also the target ceiling.
    public let maximum: Int
    /// Amounts offered as quick-add chips, in canonical units.
    public let presets: [Int]

    public var id: String { slug.rawValue }

    public init(
        slug: EventKind,
        label: String,
        emoji: String,
        unit: MetricUnit,
        defaultMinimum: Int,
        defaultGoal: Int,
        maximum: Int,
        presets: [Int]
    ) {
        self.slug = slug
        self.label = label
        self.emoji = emoji
        self.unit = unit
        self.defaultMinimum = defaultMinimum
        self.defaultGoal = defaultGoal
        self.maximum = maximum
        self.presets = presets
    }

    /// Today's `amount` measured against this metric's built-in targets. A
    /// connection's own per-member target overrides the goal/minimum where the
    /// caller has one; see `MetricCatalogue` and the recap payload.
    public func progress(amount: Int, minimum: Int? = nil, goal: Int? = nil) -> MetricProgress {
        MetricProgress(amount: amount, minimum: minimum ?? defaultMinimum, goal: goal ?? defaultGoal)
    }

    /// "1,500 ml" / "8,000 steps" / "30 min" — the amount read in this metric's
    /// unit, the kind's label supplying the noun a bare count has no symbol for.
    public func readout(_ amount: Int, locale: Locale = .current) -> String {
        if unit.symbol.isEmpty {
            return "\(amount.formatted(.number.locale(locale))) \(label.lowercased())"
        }
        return unit.label(amount, locale: locale)
    }
}

/// The built-in metrics, and resolution of a slug to a definition (#386).
///
/// Water is always present as the hero, with exactly the figures `WaterAmount`
/// has shipped so the generalisation changes nothing a water user sees. Steps
/// and exercise are offered as built-in templates a connection can enable; a
/// connection may also define its own as a `MomentKind` that tracks an amount.
public enum MetricCatalogue {
    /// The hero. ml, with `WaterAmount`'s own defaults, chips and ceiling, so a
    /// water metric resolved through here is identical to the bespoke type.
    public static let water = MetricDefinition(
        slug: .water,
        label: "Water",
        emoji: "💧",
        unit: .millilitres,
        defaultMinimum: WaterAmount.defaultMinimum,
        defaultGoal: WaterAmount.defaultRecommended,
        maximum: WaterAmount.maximum,
        presets: WaterAmount.presets.map(\.ml)
    )

    /// A step count: a plain number toward a daily goal.
    public static let steps = MetricDefinition(
        slug: EventKind(rawValue: "steps"),
        label: "Steps",
        emoji: "👟",
        unit: .count,
        defaultMinimum: 5000,
        defaultGoal: 10000,
        maximum: 200_000,
        presets: [1000, 2500, 5000]
    )

    /// Exercise minutes toward a daily goal.
    public static let exercise = MetricDefinition(
        slug: EventKind(rawValue: "exercise"),
        label: "Exercise",
        emoji: "🏃",
        unit: .minutes,
        defaultMinimum: 20,
        defaultGoal: 30,
        maximum: 1440,
        presets: [10, 20, 30]
    )

    /// Every built-in, water first (it is the hero, and shown first).
    public static let builtins: [MetricDefinition] = [water, steps, exercise]

    /// The built-in definition for a slug, if any.
    public static func builtin(_ slug: EventKind) -> MetricDefinition? {
        builtins.first { $0.slug == slug }
    }

    /// Whether a slug names a built-in metric.
    public static func isBuiltinMetric(_ slug: EventKind) -> Bool {
        builtin(slug) != nil
    }

    /// Resolve a slug to a definition, falling back to a plain-count metric so a
    /// connection's own tracked kind (a `MomentKind` with an amount) is never
    /// unresolved. The label/emoji a caller already holds for a custom kind are
    /// passed so the fallback is drawn like its moment.
    public static func resolve(
        _ slug: EventKind,
        label: String? = nil,
        emoji: String? = nil,
        unit: MetricUnit = .count,
        goal: Int? = nil
    ) -> MetricDefinition {
        if let builtin = builtin(slug) { return builtin }
        return MetricDefinition(
            slug: slug,
            label: label ?? MomentSlug.humanised(slug),
            emoji: emoji?.isEmpty == false ? emoji! : MomentCatalogue.fallbackEmoji,
            unit: unit,
            defaultMinimum: 0,
            defaultGoal: max(goal ?? 1, 1),
            maximum: 1_000_000,
            presets: []
        )
    }
}
