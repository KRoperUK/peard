import PeardCore
import SwiftUI

/// How much of a metric: a chip per preset and a field for any other (#390).
///
/// The generalisation of `WaterAmountPicker` to a `MetricDefinition`. Water keeps
/// its own picker because it has two display units — millilitres and fluid ounces
/// — and converts at the edge; a count or a number of minutes has no use for
/// that. Everything else is the same shape: presets in the metric's canonical
/// unit, and a typed value parsed against the metric's own ceiling.
///
/// Shown inside the quick-send window when the moment counts toward a metric.
/// Choosing an amount holds the send, like typing a note, so the countdown
/// cannot fire while somebody is still deciding.
struct MetricAmountPicker: View {
    let definition: MetricDefinition
    /// What is chosen now, or `nil` when nothing is.
    let amount: Int?
    /// Called when the custom field is focused, before a figure has parsed.
    var onBeginEditing: (() -> Void)?
    let onSelect: (Int?) -> Void

    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private var unit: MetricUnit { definition.unit }

    private var isPreset: Bool {
        guard let amount else { return false }
        return definition.presets.contains(amount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(definition.presets, id: \.self) { preset in
                    chip(preset)
                }
                customField
            }

            if let amount {
                Text(definition.readout(amount))
                    .font(.caption2.bold())
                    .foregroundStyle(PearColor.textSecondary)
            } else {
                Text("How much? Pick a size, or log it without one.")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)
            }
        }
    }

    private func chip(_ preset: Int) -> some View {
        let selected = amount == preset
        return Button {
            custom = ""
            customFocused = false
            onSelect(selected ? nil : preset)
        } label: {
            Text(unit.label(preset))
                .font(.footnote.bold())
                .foregroundStyle(selected ? PearColor.onAccent : PearColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(
                    selected ? PearColor.accent : PearColor.surface,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(definition.readout(preset))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customField: some View {
        HStack(spacing: 4) {
            TextField("", text: $custom, prompt: Text("Other"))
                .keyboardType(.numberPad)
                .focused($customFocused)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 40)
                .accessibilityLabel("Custom amount in \(unit.spokenName(label: definition.label))")
                .onChange(of: custom) { _, text in
                    // Digits only, bounded so a paste cannot overflow; the
                    // metric's own ceiling is what `parse` enforces.
                    let digits = String(text.filter(\.isNumber).prefix(7))
                    if digits != text { custom = digits }
                    onSelect(unit.parse(digits, maximum: definition.maximum))
                }
                .onChange(of: customFocused) { _, focused in
                    if focused { onBeginEditing?() }
                }
            Text(unit.symbol)
                .font(.footnote)
                .foregroundStyle(PearColor.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    !custom.isEmpty && !isPreset && amount != nil ? PearColor.accent : .clear,
                    lineWidth: 2
                )
        )
    }
}
