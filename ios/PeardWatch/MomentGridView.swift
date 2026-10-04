import PeardCore
import SwiftUI

/// The moment grid: a tap logs to the connection shown. Above it, only what
/// earns its space on a small screen (issue #287) — the last moment again, and
/// one line of today's counts.
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
                if let again = WatchGlance.logAgain(lastKind: model.lastLoggedKind, in: model.moments, firstRow: columns.count) {
                    logAgainTile(for: again)
                }
                if let today = model.today, let line = WatchGlance.todayLine(today) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .accessibilityLabel(WatchGlance.todayAccessibilityLabel(today) ?? line)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.moments) { moment in
                        button(for: moment)
                    }
                }
                .padding(.horizontal, 4)
                if model.waitingCount > 0 {
                    Label(
                        model.waitingCount == 1 ? "1 waiting to send" : "\(model.waitingCount) waiting to send",
                        systemImage: "clock"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
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
                case .queued: Image(systemName: "clock.fill").foregroundStyle(PearColor.accent)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PearColor.error)
                case nil: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Self.accessibilityLabel(moment, state))
    }

    /// The last moment logged from the watch, full width above the grid: the
    /// likeliest next tap, without scrolling for it on a small screen. Shares
    /// the grid button's state, since it logs the same moment.
    private func logAgainTile(for moment: WidgetFeed.AvailableMoment) -> some View {
        let state = model.logStates[moment.kind.rawValue]
        return Button {
            Task { await model.log(moment) }
        } label: {
            HStack(spacing: 6) {
                Text(moment.emoji).font(.title3)
                Text(moment.label).lineLimit(1)
                Spacer(minLength: 0)
                switch state {
                case .sending: ProgressView().frame(width: 20, height: 20)
                case .logged: Image(systemName: "checkmark.circle.fill").foregroundStyle(PearColor.accent)
                case .queued: Image(systemName: "clock.fill").foregroundStyle(PearColor.accent)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PearColor.error)
                case nil: Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 4)
        .accessibilityLabel(state == nil ? "Log \(moment.label) again" : Self.accessibilityLabel(moment, state))
    }

    static func accessibilityLabel(_ moment: WidgetFeed.AvailableMoment, _ state: WatchModel.LogState?) -> String {
        switch state {
        case .sending: return "Logging \(moment.label)"
        case .logged: return "\(moment.label) logged"
        case .queued: return "\(moment.label) saved, sends when back online"
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
