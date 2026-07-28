import PeardCore
import SwiftUI

/// Adding a moment beyond the three built-ins: pick a recommendation, or invent
/// one with a label and an emoji.
///
/// Anything added here is published to the connection, so the other members see
/// the same emoji and label rather than a bare slug.
struct MomentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: HomeModel

    @State private var label = ""
    @State private var emoji = "🍐"
    @State private var showsEmojiField = false
    @FocusState private var labelFocused: Bool
    @FocusState private var emojiFieldFocused: Bool

    private var slugPreview: String { MomentSlug.make(from: label) }
    private var canAdd: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.busy == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    customSection

                    if !model.suggestedMoments.isEmpty {
                        suggestionsSection
                    }

                    if !publishedMoments.isEmpty {
                        publishedSection
                    }
                }
                .padding(20)
            }
            .background(PearColor.background)
            .navigationTitle("Add a moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Custom

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Make your own")

            HStack(spacing: 10) {
                Button {
                    showsEmojiField = false
                    labelFocused = false
                } label: {
                    Text(emoji)
                        .font(.system(size: 34))
                        .frame(width: 60, height: 60)
                        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chosen emoji: \(emoji)")

                TextField("", text: $label, prompt: Text("Name it — dog walk, gym, tea…"))
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

            emojiGrid

            if !label.isEmpty {
                Text("Everyone will see \(emoji) \(label). Recorded as \(slugPreview).")
                    .font(.caption)
                    .foregroundStyle(PearColor.textTertiary)
            }

            Button {
                let chosenLabel = label
                let chosenEmoji = emoji
                dismiss()
                Task { await model.addCustomMoment(label: chosenLabel, emoji: chosenEmoji) }
            } label: {
                ZStack {
                    if model.busy == .publishingKind {
                        ProgressView().tint(.white)
                    } else {
                        Text("Add and send")
                            .font(.body.bold())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .padding(.vertical, 14)
                .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .opacity(canAdd ? 1 : 0.5)
        }
    }

    /// A grid rather than the system emoji keyboard: it is one tap, and it keeps
    /// the choice to single glyphs that render at tally size.
    private var emojiGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(MomentEmoji.suggestions, id: \.self) { suggestion in
                    Button {
                        emoji = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                suggestion == emoji ? PearColor.accent.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(suggestion)")
                }
            }

            if showsEmojiField {
                TextField("", text: $emoji, prompt: Text("Type any emoji"))
                    .focused($emojiFieldFocused)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: emoji) { _, newValue in
                        // Keep a single glyph, whatever the emoji keyboard sends.
                        emoji = MomentEmoji.first(in: newValue) ?? MomentCatalogue.fallbackEmoji
                    }
                    .accessibilityLabel("Custom emoji")
            } else {
                Button("Use another emoji…") {
                    showsEmojiField = true
                    emojiFieldFocused = true
                }
                .font(.footnote)
                .foregroundStyle(PearColor.accent)
            }
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recommended")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.suggestedMoments) { moment in
                    Button {
                        dismiss()
                        Task { await model.addSuggested(moment: moment) }
                    } label: {
                        VStack(spacing: 4) {
                            Text(moment.emoji).font(.title)
                            Text(moment.label)
                                .font(.caption.bold())
                                .foregroundStyle(PearColor.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy != nil)
                    .accessibilityLabel("Add \(moment.label)")
                }
            }
        }
    }

    // MARK: Published

    private var publishedMoments: [Moment] {
        model.moments.filter {
            if case .custom = $0.origin { return true }
            return false
        }
    }

    private var publishedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Added to this connection")

            VStack(spacing: 0) {
                ForEach(publishedMoments) { moment in
                    HStack(spacing: 10) {
                        Text(moment.emoji)
                        Text(moment.label)
                            .font(.subheadline)
                            .foregroundStyle(PearColor.textPrimary)
                        Spacer()
                        Button {
                            Task { await model.removeCustom(moment: moment) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.footnote)
                                .foregroundStyle(PearColor.error)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(moment.label)")
                    }
                    .padding(.vertical, 10)

                    if moment.id != publishedMoments.last?.id {
                        Divider().background(PearColor.divider)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))

            Text("Removing a moment stops it being offered. Past tallies keep counting.")
                .font(.caption)
                .foregroundStyle(PearColor.textTertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(PearColor.textPrimary)
    }
}
