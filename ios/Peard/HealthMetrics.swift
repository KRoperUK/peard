import Foundation
import HealthKit
import PeardCore

/// Where a tracked metric's daily total comes from when it is not a moment.
///
/// Steps and exercise are the two metrics a phone can answer by itself, so they
/// are read from Apple Health and pushed to the connection as a per-day total
/// (#411). Read-only: the app requests no write access and never saves a sample.
///
/// The protocol exists so `HomeModel` can be tested without a Health store —
/// and so the app still builds and runs where HealthKit has no data (iPad).
protocol HealthMetricsProviding {
    /// False on a device with no Health database; every call then does nothing.
    var isAvailable: Bool { get }
    /// Whether this provider can read the metric at all.
    func supports(_ metric: EventKind) -> Bool
    /// Asks for read access to the supported metrics. Denial is not an error:
    /// the metric still works by hand.
    func requestAuthorization(for metrics: [EventKind]) async -> Bool
    /// Today's cumulative totals in each metric's canonical unit, from the start
    /// of the local day to `now`. Metrics that cannot be read are omitted.
    func todayTotals(for metrics: [EventKind], now: Date, calendar: Calendar) async -> [EventKind: Int]
}

/// The provider tests and previews get: nothing to read, nothing to ask.
struct DisabledHealthMetrics: HealthMetricsProviding {
    var isAvailable: Bool { false }
    func supports(_ metric: EventKind) -> Bool { false }
    func requestAuthorization(for metrics: [EventKind]) async -> Bool { false }
    func todayTotals(for metrics: [EventKind], now: Date, calendar: Calendar) async -> [EventKind: Int] { [:] }
}

/// Apple Health, read-only (#411).
///
/// Steps come from `stepCount` and exercise from `appleExerciseTime` (the
/// minutes Apple's own Exercise ring counts), both as a cumulative sum from the
/// start of the member's local day. Canonical units match the metric
/// definitions: a step count and whole minutes, so the value goes to the server
/// as it would from the amount picker.
final class HealthKitMetricsProvider: HealthMetricsProviding {
    private let store = HKHealthStore()

    /// The two built-in metrics this can fill. A custom metric has no Health
    /// type, so it is left to manual logging.
    static let steps = EventKind(rawValue: "steps")
    static let exercise = EventKind(rawValue: "exercise")

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func supports(_ metric: EventKind) -> Bool {
        Self.quantityType(for: metric) != nil
    }

    private static func quantityType(for metric: EventKind) -> HKQuantityType? {
        switch metric.rawValue {
        case steps.rawValue: return HKQuantityType(.stepCount)
        case exercise.rawValue: return HKQuantityType(.appleExerciseTime)
        default: return nil
        }
    }

    /// The unit each metric is stored in, matching `MetricUnit`.
    private static func unit(for metric: EventKind) -> HKUnit? {
        switch metric.rawValue {
        case steps.rawValue: return .count()
        case exercise.rawValue: return .minute()
        default: return nil
        }
    }

    func requestAuthorization(for metrics: [EventKind]) async -> Bool {
        guard isAvailable else { return false }
        let types = Set(metrics.compactMap { Self.quantityType(for: $0) })
        guard !types.isEmpty else { return false }
        do {
            // Read-only, deliberately: an empty share set means the app cannot
            // add or change anything in Health.
            try await store.requestAuthorization(toShare: [], read: types)
            return true
        } catch {
            return false
        }
    }

    func todayTotals(for metrics: [EventKind], now: Date, calendar: Calendar) async -> [EventKind: Int] {
        guard isAvailable else { return [:] }
        let start = calendar.startOfDay(for: now)
        // `.strictStartDate` keeps yesterday's late samples out of today's sum.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        var totals: [EventKind: Int] = [:]
        for metric in metrics {
            guard let type = Self.quantityType(for: metric), let unit = Self.unit(for: metric) else {
                continue
            }
            let total = await cumulativeSum(type: type, unit: unit, predicate: predicate)
            if let total {
                totals[metric] = total
            }
        }
        return totals
    }

    /// One cumulative-sum query, bridged to async. A failed or unauthorised
    /// query answers nil rather than zero: zero would overwrite a real total.
    private func cumulativeSum(
        type: HKQuantityType,
        unit: HKUnit,
        predicate: NSPredicate
    ) async -> Int? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }
}
