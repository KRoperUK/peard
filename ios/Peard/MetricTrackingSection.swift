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
                    get: { model.isMetricTracked(definition) },
                    set: { model.setMetricTracked($0, definition: definition) }
                ))
                .tint(PearColor.accent)
                .foregroundStyle(PearColor.textPrimary)
                .listRowBackground(PearColor.surface)

                if model.isMetricTracked(definition) {
                    goalRow(definition)
                }
            }
        } header: {
            Text("Other metrics")
        } footer: {
            Text("A daily goal for steps, exercise and the like. Your goal is shared with the connection, where it is summed with everybody else's.")
        }
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
