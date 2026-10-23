import PeardCore
import SwiftUI

/// Daily-progress metrics beyond water (#390): steps, exercise, and the like.
///
/// Water has its own section — it has a unit switch and refill chips, and the
/// product is built around it — so this covers the templates that are just a
/// toggle and a daily goal. Turning one on writes this user's own target
/// (`POST /api/peard/metric/target`, #387), which is what makes the server start
/// reporting the metric in `feed.metrics` and what the watch complication's
/// picker offers.
///
/// The goal is per person and summed by the server into the connection's goal,
/// the same shape water's targets already use (#335).
struct MetricTrackingSection: View {
    let model: HomeModel

    var body: some View {
        Section {
            ForEach(model.trackableMetrics) { definition in
                Toggle("Track \(definition.label.lowercased())", isOn: Binding(
                    get: { model.isMetricTrackedByMe(definition) },
                    set: { tracked in
                        model.setMetricTracked(tracked, definition: definition)
                        // Turning it on asks Apple Health for read access, once.
                        // Denial is fine: logging an amount by hand still works.
                        if tracked {
                            Task { await model.enableHealthSync(for: definition) }
                        }
                    }
                ))
                .tint(PearColor.accent)
                .foregroundStyle(PearColor.textPrimary)
                .listRowBackground(PearColor.surface)

                if model.isMetricTrackedByMe(definition) {
                    goalRow(definition)
                } else if model.isMetricTrackedByOthersOnly(definition) {
                    // The connection already tracks this because a partner turned
                    // it on. Say so, so the off switch is not a surprise, and make
                    // joining in — which grants this device's Health access — one
                    // tap instead of the old off/on dance.
                    trackedByConnectionRow(definition)
                }
            }
        } header: {
            Text("Other metrics")
        } footer: {
            Text("A daily goal for steps, exercise and the like. Your goal is shared with the connection, where it is summed with everybody else's. Apple Health is read-only: turning one on asks for access on this device, and denying it leaves the metric to log by hand.")
        }
    }

    /// Shown when a partner tracks a metric this person has not joined: a one-tap
    /// way to start tracking it themselves, which sets their own goal and
    /// prompts for Apple Health on this device.
    private func trackedByConnectionRow(_ definition: MetricDefinition) -> some View {
        Button {
            model.setMetricTracked(true, definition: definition)
            if model.healthCanFill(definition) {
                Task { await model.enableHealthSync(for: definition) }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tracked by your connection")
                        .font(.subheadline)
                        .foregroundStyle(PearColor.textPrimary)
                    Text(model.healthCanFill(definition)
                        ? String(localized: "Track it too to add your own goal and connect Apple Health.")
                        : String(localized: "Track it too to add your own goal."))
                        .font(.caption2)
                        .foregroundStyle(PearColor.textTertiary)
                }
                Spacer(minLength: 8)
                Text("Track")
                    .font(.subheadline.bold())
                    .foregroundStyle(PearColor.accent)
            }
        }
        .listRowBackground(PearColor.surface)
        .accessibilityLabel(String(localized: "Track \(definition.label.lowercased()) too"))
    }

    /// One goal, stepped in the metric's own unit — 500 steps, 5 minutes — so a
    /// run of taps lands on a round number rather than an arbitrary one.
    private func goalRow(_ definition: MetricDefinition) -> some View {
        let goal = model.metricGoal(for: definition)
        return Stepper(
            value: Binding(
                get: { goal },
                set: { model.setMetricGoal($0, definition: definition) }
            ),
            in: definition.unit.step...definition.maximum,
            step: definition.unit.step
        ) {
            HStack {
                Text("Daily goal").foregroundStyle(PearColor.textPrimary)
                Spacer()
                Text(definition.readout(goal))
                    .monospacedDigit()
                    .foregroundStyle(PearColor.textSecondary)
            }
        }
        .listRowBackground(PearColor.surface)
        .accessibilityLabel(String(localized: "Daily \(definition.label.lowercased()) goal"))
        .accessibilityValue(definition.readout(goal))
    }
}
