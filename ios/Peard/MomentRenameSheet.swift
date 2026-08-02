import PeardCore
import SwiftUI

/// Renaming a moment the connection already publishes, or giving it a different
/// emoji.
///
/// Its own sheet rather than an inline field, because the change is not private:
/// it relabels the moment for everybody in the connection and everywhere it has
/// already been logged. That is the right behaviour — a typo should disappear
/// from the history, not survive beside its correction as a second moment
/// splitting the tallies — but it is worth a screen that says so before you
/// commit to it.
struct MomentRenameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let moment: Moment
    let onSave: (String, String) -> Void

    @State private var label: String
    @State private var emoji: String
    @FocusState private var labelFocused: Bool
    @State private var emojiFieldFocused = false

    init(moment: Moment, onSave: @escaping (String, String) -> Void) {
        self.moment = moment
        self.onSave = onSave
        _label = State(initialValue: moment.label)
        _emoji = State(initialValue: moment.emoji)
    }

    private var trimmed: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var changed: Bool {
        trimmed != moment.label || emoji != moment.emoji
    }

    private var canSave: Bool { !trimmed.isEmpty && changed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    fields
                    explanation
                    saveButton
                }
                .padding(20)
            }
            .background(PearColor.background)
            .navigationTitle("Edit moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Deliberately the same two controls, in the same order, as the "make your
    /// own" section — this is the same decision being revisited.
    private var fields: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(PearColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(emojiFieldFocused ? PearColor.accent : .clear, lineWidth: 2)
                    )
                EmojiField(emoji: $emoji, isFocused: emojiFieldFocused)
                    .frame(width: 56, height: 44)
            }
            .frame(width: 60, height: 60)
            .contentShape(Rectangle())
            .onTapGesture {
                labelFocused = false
                emojiFieldFocused = true
            }
            .accessibilityLabel("Moment emoji, currently \(emoji)")
            .accessibilityHint("Opens the emoji keyboard")

            TextField("", text: $label, prompt: Text("Name it"))
                .focused($labelFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Moment name")
                .onChange(of: label) { _, newValue in
                    label = String(newValue.prefix(MomentSlug.maxLength))
                    // A typed emoji is a choice of emoji, not part of the name.
                    if let typed = MomentEmoji.first(in: label) {
                        emoji = typed
                        label = label.filter { !MomentEmoji.isEmoji($0) }
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
        }
    }

    /// Says the two things somebody needs to know before saving: that it is not
    /// only their copy, and that it reaches moments already logged.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Everyone in this connection will see \(emoji) \(trimmed.isEmpty ? moment.label : trimmed).")
            Text("Moments already logged are relabelled too — they are still the same moment underneath.")
        }
        .font(.caption)
        .foregroundStyle(PearColor.textTertiary)
    }

    private var saveButton: some View {
        Button {
            let chosenLabel = trimmed
            let chosenEmoji = emoji
            dismiss()
            onSave(chosenLabel, chosenEmoji)
        } label: {
            Text("Save")
                .font(.body.bold())
                .foregroundStyle(PearColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 24)
                .padding(.vertical, 14)
                .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.5)
    }
}
