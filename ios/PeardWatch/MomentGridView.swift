import PeardCore
import SwiftUI

/// The moment grid and nothing else: a tap logs to the connection shown.
struct MomentGridView: View {
    @Bindable var model: WatchModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.selected?.title ?? "Pear'd")
                .toolbar {
                    if model.connections.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                ConnectionPicker(model: model)
                            } label: {
                                Image(systemName: "person.2")
                            }
                            .accessibilityLabel("Choose connection")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            message("🍐", "Open Pear'd on your iPhone and sign in.")
        case .loading:
            ProgressView()
        case .failed(let text):
            VStack(spacing: 8) {
                message("⚠️", text)
                Button("Try again") { Task { await model.load() } }
            }
        case .ready:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.moments) { moment in
                        button(for: moment)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func button(for moment: WidgetFeed.AvailableMoment) -> some View {
        let state = model.logStates[moment.kind.rawValue]
        return Button {
            Task { await model.log(moment) }
        } label: {
            ZStack {
                Text(moment.emoji)
                    .font(.title2)
                    .opacity(state == nil ? 1 : 0.35)
                switch state {
                case .sending: ProgressView()
                case .logged: Image(systemName: "checkmark.circle.fill").foregroundStyle(PearColor.accent)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PearColor.error)
                case nil: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Self.accessibilityLabel(moment, state))
    }

    static func accessibilityLabel(_ moment: WidgetFeed.AvailableMoment, _ state: WatchModel.LogState?) -> String {
        switch state {
        case .sending: return "Logging \(moment.label)"
        case .logged: return "\(moment.label) logged"
        case .failed: return "Couldn't log \(moment.label)"
        case nil: return "Log \(moment.label)"
        }
    }

    private func message(_ emoji: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Text(emoji).font(.largeTitle)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct ConnectionPicker: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(model.connections) { connection in
            Button {
                model.selectedID = connection.id
                Haptics.play(.switchedConnection)
                dismiss()
            } label: {
                HStack {
                    Text(connection.title)
                    Spacer()
                    if connection.id == model.selected?.id {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .accessibilityAddTraits(connection.id == model.selected?.id ? .isSelected : [])
        }
        .navigationTitle("Connections")
    }
}
