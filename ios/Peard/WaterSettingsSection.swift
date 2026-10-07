import PeardCore
import SwiftUI

/// "Water": this connection's daily targets, refill sizes and on/off switch
/// (#322).
///
/// Its own view rather than more of `ConnectionSettingsView`, which is long
/// enough already. Every change goes through `HomeModel.updateWaterConfig`, so
/// the quick-send window and the Tallies tab pick it up as it is made. The
/// settings are this device's, per connection — see `WaterConfig`.
///
/// Sizes and targets are shown, and a new size typed, in the user's unit (#324,
/// `WaterUnitSection`); the config itself is always millilitres.
struct WaterSettingsSection: View {
    let model: HomeModel

    @State private var newSize = ""
    @FocusState private var newSizeFocused: Bool

    private var config: WaterConfig { model.waterConfig }
    private var unit: WaterUnit { model.waterUnit }

    var body: some View {
        Section {
            Toggle("Track water", isOn: Binding(
                get: { config.isEnabled },
                set: { on in model.updateWaterConfig { $0.isEnabled = on } }
            ))
            .tint(PearColor.accent)
            .foregroundStyle(PearColor.textPrimary)
            .listRowBackground(PearColor.surface)
        } header: {
            Text("Water")
        } footer: {
            Text(footer)
        }

        if config.isEnabled {
            targetsSection
            presetsSection
        }
    }

    private var footer: String {
        config.isEnabled
            ? "Water moments offer a size, and Tallies shows today against your targets."
            : "Water is hidden for \(model.connectionTitle). Moments already logged keep their amounts."
    }

    // MARK: Targets

    private var targetsSection: some View {
        Section {
            targetStepper(
                "Minimum",
                accessibility: "Daily minimum",
                ml: config.minimum,
                range: WaterConfig.step...config.recommended
            ) { ml in model.updateWaterConfig { $0.setMinimum(ml) } }

            targetStepper(
                "Goal",
                accessibility: "Daily goal",
                ml: config.recommended,
                range: config.minimum...WaterAmount.maximum
            ) { ml in model.updateWaterConfig { $0.setRecommended(ml) } }
        } header: {
            Text("Daily targets")
        } footer: {
            Text("The minimum cannot be more than the goal.")
        }
    }

    /// One target. In millilitres it is the plain stepper it has always been; in
    /// fluid ounces it steps along whole multiples of 4 fl oz (`WaterUnit.stepped`)
    /// rather than 100 ml, which would read 50.7, 54.1, 57.5. Either way `set`
    /// is handed millilitres and the range is millilitres.
    private func targetStepper(
        _ title: String,
        accessibility: String,
        ml: Int,
        range: ClosedRange<Int>,
        set: @escaping (Int) -> Void
    ) -> some View {
        let value = WaterAmount.label(ml, unit: unit)
        return Group {
            if unit == .millilitres {
                Stepper(
                    value: Binding(get: { ml }, set: set),
                    in: range,
                    step: WaterConfig.step
                ) {
                    row(title, value)
                }
            } else {
                Stepper {
                    row(title, value)
                } onIncrement: {
                    set(min(unit.stepped(ml, up: true), range.upperBound))
                } onDecrement: {
                    set(max(unit.stepped(ml, up: false), range.lowerBound))
                }
            }
        }
        .listRowBackground(PearColor.surface)
        .accessibilityLabel(accessibility)
        .accessibilityValue(value)
    }

    // MARK: Sizes

    private var presetsSection: some View {
        Section {
            ForEach(config.presets) { preset in
                HStack {
                    Text(preset.label(in: unit))
                        .foregroundStyle(PearColor.textPrimary)
                    Spacer()
                    Button(role: .destructive) {
                        model.updateWaterConfig { $0.removePreset(preset.ml) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(PearColor.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(preset.label(in: unit))")
                }
                .listRowBackground(PearColor.surface)
            }

            if config.canAddPreset {
                HStack {
                    TextField("", text: $newSize, prompt: Text("Add a size"))
                        .keyboardType(.numberPad)
                        .focused($newSizeFocused)
                        .foregroundStyle(PearColor.textPrimary)
                        .onSubmit(addSize)
                        .accessibilityLabel("New size in \(unit.spokenName)")
                        .onChange(of: unit) { newSize = "" }
                    Text(unit.symbol)
                        .foregroundStyle(PearColor.textSecondary)
                    Button("Add", action: addSize)
                        .foregroundStyle(canAdd ? PearColor.accent : PearColor.textTertiary)
                        .disabled(!canAdd)
                }
                .listRowBackground(PearColor.surface)
            }

            if config != .standard {
                Button("Reset water settings") {
                    newSize = ""
                    newSizeFocused = false
                    model.updateWaterConfig { $0 = WaterConfig(isEnabled: $0.isEnabled) }
                }
                .foregroundStyle(PearColor.accent)
                .listRowBackground(PearColor.surface)
            }
        } header: {
            Text("Refill sizes")
        } footer: {
            Text(sizesFooter)
        }
    }

    private var sizesFooter: String {
        config.canAddPreset
            ? "Offered as chips when logging water. Up to \(WaterConfig.maximumPresets); \"Other\" is always there."
            : "That's all \(WaterConfig.maximumPresets) sizes. Remove one to add another."
    }

    private var canAdd: Bool {
        guard let ml = WaterAmount.parse(newSize, unit: unit) else { return false }
        return !config.presetMLs.contains(ml)
    }

    private func addSize() {
        guard let ml = WaterAmount.parse(newSize, unit: unit) else { return }
        model.updateWaterConfig { $0.addPreset(ml) }
        newSize = ""
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(PearColor.textPrimary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(PearColor.textSecondary)
        }
    }
}
