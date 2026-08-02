import PeardCore
import SwiftUI

/// Changing a moment after the fact: what it was, and what you said about it.
///
/// A moment is logged in one tap, on purpose — which is exactly why it is easy
/// to tap the wrong one, or to think of the detail worth adding a minute later.
/// Until now the only remedy was to log a second moment and leave the first one
/// wrong, which quietly makes the tallies wrong too.
///
/// Only the author's own moments reach this screen. Editing somebody else's
/// account of their own evening is not something being in a group entitles you
/// to, and the server refuses it independently.
struct MomentEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let post: Post
    let moments: [Moment]
    let model: HistoryModel

    @State private var note: String
    @State private var kind: EventKind?
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @FocusState private var noteFocused: Bool

    init(post: Post, moments: [Moment], model: HistoryModel) {
        self.post = post
        self.moments = moments
        self.model = model
        _note = State(initialValue: post.note ?? "")
        _kind = State(initialValue: post.eventKind)
    }

    /// A photo has no moment kind, so there is nothing to pick between — its
    /// note is a caption, and that is the whole of what can change.
    private var canChangeKind: Bool { post.type == .event }

    private var hasChanges: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines) != (post.note ?? "")
            || kind != post.eventKind
    }

    var body: some View {
        NavigationStack {
            Form {
                if canChangeKind {
                    kindSection
                }
                noteSection
                deleteSection
            }
            .scrollContentBackground(.hidden)
            .background(PearColor.background)
            .navigationTitle("Edit moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasChanges || isSaving)
                }
            }
            .confirmationDialog(
                "Delete this moment?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteMoment() }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Said plainly rather than softened: everybody in the connection
                // has already seen it, and it goes from their timeline too.
                Text("It goes from the shared timeline and stops counting towards the tallies. This cannot be undone.")
            }
        }
    }

    // MARK: Sections

    private var kindSection: some View {
        Section {
            // A grid rather than a picker: the moments are emoji, and picking
            // one is a thing you do by looking, not by reading a list.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(moments) { moment in
                    Button {
                        kind = moment.kind
                    } label: {
                        VStack(spacing: 4) {
                            Text(moment.emoji).font(.title2)
                            Text(moment.label)
                                .font(.caption2)
                                .foregroundStyle(PearColor.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            moment.kind == kind ? PearColor.accent.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(moment.kind == kind ? PearColor.accent : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(moment.label)
                    .accessibilityAddTraits(moment.kind == kind ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        } header: {
            Text("What it was")
        } footer: {
            // The tallies are the reason this matters more than it looks.
            Text("Changing this moves it in everybody's tallies too.")
        }
    }

    private var noteSection: some View {
        Section {
            TextField(
                "",
                text: $note,
                prompt: Text(post.type == .photo ? "Caption…" : "Add a note…"),
                axis: .vertical
            )
            .focused($noteFocused)
            .lineLimit(1...5)
            .foregroundStyle(PearColor.textPrimary)
            .onChange(of: note) { _, newValue in
                // Being told after the fact that it was too long is a worse way
                // to find out.
                note = PostNote.capped(newValue)
            }
            .accessibilityLabel(post.type == .photo ? "Caption" : "Note")
        } header: {
            Text(post.type == .photo ? "Caption" : "Note")
        } footer: {
            if note.count > 200 {
                Text("\(PostNote.limit - note.count) characters left")
            } else {
                Text("Leave it empty to take the note back.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete this moment", systemImage: "trash")
            }
            .disabled(isSaving)
        }
    }

    // MARK: Actions

    private func save() {
        isSaving = true
        Task {
            let saved = await model.edit(post, note: note, kind: kind)
            isSaving = false
            // Left open on failure, with the error on the timeline behind it, so
            // nothing typed is lost to a dismissed sheet.
            if saved { dismiss() }
        }
    }

    private func deleteMoment() {
        isSaving = true
        Task {
            let gone = await model.delete(post)
            isSaving = false
            if gone { dismiss() }
        }
    }
}
