import PeardCore
import SwiftUI

/// The share sheet: the photo as it will be sent, and three choices — who it
/// is for, what moment it is, and a caption. Nothing else, because anything
/// more belongs in the app.
struct ShareView: View {
    @Bindable var model: ShareModel
    let onCancel: () -> Void
    let onSent: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to Pear'd")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    if model.phase == .ready {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") {
                                if model.send() { onSent() }
                            }
                            .fontWeight(.semibold)
                            .disabled(!model.canSend)
                        }
                    }
                }
        }
        .tint(PearColor.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .tint(PearColor.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            message("🍐 Sign in to Pear'd first, then share again.")
        case .failed(let text):
            message(text)
        case .ready:
            form
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(PearColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        Form {
            if let preview = model.preview {
                Section {
                    Image(uiImage: preview)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("The photo you are sharing")
                }
                .listRowBackground(Color.clear)
            }

            Section {
                if model.isOffline {
                    Text("The connection you last had open")
                        .foregroundStyle(PearColor.textSecondary)
                } else {
                    Picker("Connection", selection: $model.selectedID) {
                        ForEach(model.connections) { connection in
                            Text(connection.title).tag(Optional(connection.id))
                        }
                    }
                }

                Picker("Moment", selection: $model.moment) {
                    Text("Just the photo").tag(WidgetFeed.AvailableMoment?.none)
                    ForEach(model.moments) { moment in
                        Text("\(moment.emoji) \(moment.label)").tag(Optional(moment))
                    }
                }

                TextField("Add a caption", text: $model.caption, axis: .vertical)
                    .lineLimit(1...4)
                    .onChange(of: model.caption) { _, value in
                        let capped = PostNote.capped(value)
                        if capped != value { model.caption = capped }
                    }
            } footer: {
                // Honest about when: the app does the sending, and it can only
                // do that once it is running again.
                Text("Pear'd sends it the next time it's open.")
            }
        }
    }
}
