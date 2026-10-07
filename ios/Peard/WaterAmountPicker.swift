import PeardCore
import SwiftUI

/// How much water: a chip per preset size, and a field for any other. The sizes
/// are the connection's own (#322); the caller passes them in.
///
/// Sizes are drawn, and a custom size is typed, in the user's unit (#324). What
/// goes to `onSelect` is always millilitres: a figure typed in fluid ounces is
/// converted before it leaves, so nothing downstream knows the unit exists.
///
/// Shown inside the quick-send window when the moment is water. Choosing a size
/// holds the send, like typing a note, so the countdown cannot fire while
/// somebody is still deciding; `HomeModel.setQuickSendAmount` does that.
struct WaterAmountPicker: View {
    /// What is chosen now, or `nil` when nothing is.
    let amount: Int?
    let presets: [WaterAmount.Preset]
    var unit: WaterUnit = .millilitres
    let onSelect: (Int?) -> Void

    @State private var custom = ""
    @FocusState private var customFocused: Bool

    /// What typing in the custom field means: the digits worth keeping — five
    /// litres is four digits of millilitres and three of ounces — and the
    /// millilitres they stand for, or `nil` while they are not yet a usable size.
    /// The only place a typed ounce figure becomes millilitres.
    static func entry(_ text: String, unit: WaterUnit) -> (digits: String, ml: Int?) {
        let digits = String(text.filter(\.isNumber).prefix(unit == .millilitres ? 4 : 3))
        return (digits, WaterAmount.parse(digits, unit: unit))
    }

    private var isPreset: Bool {
        presets.contains { $0.ml == amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A grid, not a row: a connection can offer up to four sizes, which
            // would not fit beside the custom field on a narrow phone.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(presets) { preset in
                    chip(preset)
                }
                customField
            }
            if let amount {
                Text("\(WaterAmount.label(amount, unit: unit)) of water")
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
            Text(preset.label(in: unit))
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
        .accessibilityLabel(preset.label(in: unit))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customField: some View {
        HStack(spacing: 4) {
            TextField("", text: $custom, prompt: Text("Other"))
                .keyboardType(.numberPad)
                .focused($customFocused)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 40)
                .accessibilityLabel("Custom amount in \(unit.spokenName)")
                .onChange(of: custom) { _, text in
                    let (digits, ml) = Self.entry(text, unit: unit)
                    if digits != text { custom = digits }
                    onSelect(ml)
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
                .strokeBorder(!custom.isEmpty && !isPreset && amount != nil ? PearColor.accent : .clear, lineWidth: 2)
        )
    }
}
