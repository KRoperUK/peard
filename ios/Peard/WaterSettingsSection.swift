import PeardCore
import SwiftUI

/// "Water": this connection's daily targets, refill sizes and on/off switch
/// (#322).
///
/// Its own view rather than more of `ConnectionSettingsView`, which is long
/// enough already. Every change goes through `HomeModel.updateWaterConfig`, so
/// the quick-send window and the Tallies tab pick it up as it is made. The
/// settings are this device's, per connection — see `WaterConfig`.
struct WaterSettingsSection: View {
    let model: HomeModel

    @State private var newSize = ""
    @FocusState private var newSizeFocused: Bool

    private var config: WaterConfig { model.waterConfig }

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
            Stepper(
                value: Binding(
                    get: { config.minimum },
                    set: { ml in model.updateWaterConfig { $0.setMinimum(ml) } }
                ),
                in: WaterConfig.step...config.recommended,
                step: WaterConfig.step
            ) {
                row("Minimum", WaterAmount.label(config.minimum))
            }
            .listRowBackground(PearColor.surface)
            .accessibilityLabel("Daily minimum")
            .accessibilityValue(WaterAmount.label(config.minimum))

            Stepper(
                value: Binding(
                    get: { config.recommended },
                    set: { ml in model.updateWaterConfig { $0.setRecommended(ml) } }
                ),
                in: config.minimum...WaterAmount.maximum,
                step: WaterConfig.step
            ) {
                row("Goal", WaterAmount.label(config.recommended))
            }
            .listRowBackground(PearColor.surface)
            .accessibilityLabel("Daily goal")
            .accessibilityValue(WaterAmount.label(config.recommended))
        } header: {
            Text("Daily targets")
        } footer: {
            Text("The minimum cannot be more than the goal.")
        }
    }

    // MARK: Sizes

    private var presetsSection: some View {
        Section {
            ForEach(config.presets) { preset in
                HStack {
                    Text(preset.label)
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
                    .accessibilityLabel("Remove \(preset.label)")
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
                        .accessibilityLabel("New size in millilitres")
                    Text("ml")
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
        guard let ml = WaterAmount.parse(newSize) else { return false }
        return !config.presetMLs.contains(ml)
    }

    private func addSize() {
        guard let ml = WaterAmount.parse(newSize) else { return }
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
