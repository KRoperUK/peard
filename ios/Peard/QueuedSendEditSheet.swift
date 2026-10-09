import PeardCore
import SwiftUI

/// Changing a moment that is still waiting to send (#313).
///
/// The sibling of `MomentEditSheet`, for a moment that has not reached the
/// server. That one asks the API to change a record; a queued send has no
/// record, so this one changes the queue — which is why it calls `AppModel`
/// rather than `HistoryModel`, and why there is no "when" section: only what
/// it was and what you said about it can be changed before it goes.
///
/// A photo's picture cannot be swapped here either. To change that, delete the
/// send and take it again.
struct QueuedSendEditSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let send: PendingSend
    let moments: [Moment]

    @State private var note: String
    @State private var kind: EventKind
    @State private var isWorking = false
    @State private var showDeleteConfirmation = false

    init(send: PendingSend, moments: [Moment]) {
        self.send = send
        self.moments = moments
        _note = State(initialValue: send.note)
        _kind = State(initialValue: send.kind)
    }

    /// A photo or a reply has no moment kind, so there is nothing to pick
    /// between — its note is a caption or the words of the reply.
    private var canChangeKind: Bool { send.postType == .event && !send.kind.isEmpty }

    private var isCaption: Bool { send.postType != .event || send.kind.isEmpty }

    private var hasChanges: Bool {
        PostNote.normalised(note) != send.note || kind != send.kind
    }

    /// Words alone, with nothing in them, would be refused by the server and
    /// lost; so a reply without a photo cannot have its words taken away.
    private var canSave: Bool {
        guard hasChanges, !isWorking else { return false }
        return send.hasPhoto || send.postType == .event || !PostNote.isEmpty(note)
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
            .navigationTitle("Edit queued moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            // An alert, centred, as on the timeline (issue #296).
            .alert("Delete this moment?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) { deleteSend() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It hasn't been sent yet, so it is removed from this phone and will not be sent. This cannot be undone.")
            }
        }
    }

    // MARK: Sections

    private var kindSection: some View {
        Section {
            // A grid rather than a picker, as in `MomentEditSheet`: the moments
            // are emoji, and picking one is a thing you do by looking.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(moments) { moment in
                    kindButton(for: moment)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        } header: {
            Text("What it was")
        }
    }

    private func kindButton(for moment: Moment) -> some View {
        let selected = moment.kind == kind
        return Button {
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
                selected ? PearColor.accent.opacity(0.22) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? PearColor.accent : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(moment.label)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var noteSection: some View {
        Section {
            TextField(
                "",
                text: $note,
                prompt: Text(isCaption ? String(localized: "Caption…") : String(localized: "Add a note…")),
                axis: .vertical
            )
            .lineLimit(1...5)
            .foregroundStyle(PearColor.textPrimary)
            .onChange(of: note) { _, newValue in
                note = PostNote.capped(newValue)
            }
            .accessibilityLabel(isCaption ? String(localized: "Caption") : String(localized: "Note"))
        } header: {
            Text(isCaption ? String(localized: "Caption") : String(localized: "Note"))
        } footer: {
            if note.count > 200 {
                Text("\(PostNote.limit - note.count) characters left")
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
            .disabled(isWorking)
        } footer: {
            Text("Waiting on this phone until the server accepts it.")
        }
    }

    // MARK: Actions

    private func save() {
        isWorking = true
        Task {
            await app.editPendingSend(id: send.id, note: note, kind: kind)
            isWorking = false
            dismiss()
        }
    }

    private func deleteSend() {
        isWorking = true
        Task {
            await app.deletePendingSend(id: send.id)
            isWorking = false
            dismiss()
        }
    }
}
