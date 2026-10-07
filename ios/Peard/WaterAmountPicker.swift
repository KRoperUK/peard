import PeardCore
import SwiftUI

/// How much water: a chip per preset size, and a field for any other.
///
/// Shown inside the quick-send window when the moment is water. Choosing a size
/// holds the send, like typing a note, so the countdown cannot fire while
/// somebody is still deciding; `HomeModel.setQuickSendAmount` does that.
struct WaterAmountPicker: View {
    /// What is chosen now, or `nil` when nothing is.
    let amount: Int?
    let onSelect: (Int?) -> Void

    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private var isPreset: Bool {
        WaterAmount.presets.contains { $0.ml == amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(WaterAmount.presets) { preset in
                    chip(preset)
                }
                customField
            }
            if let amount {
                Text("\(WaterAmount.label(amount)) of water")
                    .font(.caption2.bold())
                    .foregroundStyle(PearColor.textSecondary)
            } else {
                Text("How much? Pick a size, or log it without one.")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)
            }
        }
    }

    private func chip(_ preset: WaterAmount.Preset) -> some View {
        let selected = amount == preset.ml
        return Button {
            custom = ""
            customFocused = false
            onSelect(selected ? nil : preset.ml)
        } label: {
            Text(preset.label)
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
        .accessibilityLabel(preset.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customField: some View {
        HStack(spacing: 4) {
            TextField("", text: $custom, prompt: Text("Other"))
                .keyboardType(.numberPad)
                .focused($customFocused)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 40)
                .accessibilityLabel("Custom amount in millilitres")
                .onChange(of: custom) { _, text in
                    let digits = String(text.filter(\.isNumber).prefix(4))
                    if digits != text { custom = digits }
                    onSelect(WaterAmount.parse(digits))
                }
            Text("ml")
                .font(.footnote)
                .foregroundStyle(PearColor.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(!custom.isEmpty && !isPreset && amount != nil ? PearColor.accent : .clear, lineWidth: 2)
        )
    }
}
