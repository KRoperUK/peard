import PeardCore
import SwiftUI

/// The compact tray: one tap per moment, into a connection you can see and
/// change.
struct MomentTrayView: View {
    let model: MomentTrayModel
    let onTap: (WidgetFeed.AvailableMoment) -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().tint(PearColor.accent)
            case .signedOut:
                message("🍐 Sign in to Pear'd first, then come back here.")
            case .failed(let text):
                message(text)
            case .ready:
                tray
            }
        }
        .frame(maxWidth: .infinity)
        .background(PearColor.background)
        .animation(.easeOut(duration: 0.2), value: model.status)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(PearColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private var tray: some View {
        VStack(spacing: 8) {
            connectionBar
            summary
            // Scrolls because a connection may have published a dozen moments
            // and Messages gives the tray about as much height as one row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.moments) { moment in
                        button(for: moment)
                    }
                }
                .padding(.horizontal, 16)
            }
            statusLine
        }
        .padding(.vertical, 12)
    }

    /// What the others have been up to.
    ///
    /// Held at a stable height for the same reason the status line is: this sits
    /// directly above the buttons, and a block that grows a line when the feed
    /// lands would move them out from under somebody's thumb.
    @ViewBuilder
    private var summary: some View {
        let summary = model.summary
        VStack(spacing: 2) {
            if summary.isEmpty {
                Text("Nothing from them yet today")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textSecondary)
            } else {
                if !summary.tallies.isEmpty {
                    talliesRow(summary.heading, summary.tallies)
                }
                if let latest = summary.latest {
                    latestRow(latest)
                }
            }
        }
        .frame(minHeight: 32, alignment: .top)
        .padding(.horizontal, 16)
    }

    /// The heading earns its place: these counts exclude your own posts, so
    /// without a name on them the Coffee button appears to leave the coffee
    /// count alone.
    private func talliesRow(_ heading: String, _ tallies: [WidgetFeed.Tally]) -> some View {
        // Four fits the narrowest tray. They arrive most-frequent-first, and the
        // remainder is counted rather than quietly dropped.
        let shown = tallies.prefix(4)
        let hidden = tallies.count - shown.count
        return HStack(spacing: 8) {
            Text(heading)
                .font(.caption2)
                .foregroundStyle(PearColor.textSecondary)
                .lineLimit(1)
            ForEach(shown) { tally in
                HStack(spacing: 2) {
                    Text(tally.emoji)
                    Text("\(tally.count)").monospacedDigit()
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(tally.count) \(tally.label)")
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textSecondary)
                    .accessibilityLabel("\(hidden) more kinds")
            }
        }
    }

    private func latestRow(_ latest: MomentTrayModel.Summary.Latest) -> some View {
        HStack(spacing: 4) {
            Text(latest.emoji)
            Text(latest.author).bold()
            // The note when there is one, else what it was. The note is the more
            // interesting of the two and there is only room for one.
            if let detail = latest.note ?? (latest.label.isEmpty ? nil : latest.label) {
                Text("· \(detail)")
            }
            Spacer(minLength: 4)
            if let at = latest.at {
                Text(at, style: .relative)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .foregroundStyle(PearColor.textSecondary)
        .accessibilityElement(children: .combine)
    }

    /// Which connection this is going to, and how to change it.
    ///
    /// Always shown, even with one connection, because the question it answers —
    /// "where is this about to go?" — matters most to somebody who has just
    /// started and does not yet know how many they have. It only becomes a menu
    /// when there is a choice.
    @ViewBuilder
    private var connectionBar: some View {
        if let connection = model.selectedConnection {
            if model.canChooseConnection {
                Menu {
                    ForEach(model.connections) { option in
                        Button {
                            Task { await model.select(option.id) }
                        } label: {
                            if option.id == model.selectedID {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(connection.title)
                            .font(.caption.bold())
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(PearColor.accent)
                }
                .disabled(model.isBusy)
                .accessibilityLabel("Logging to \(connection.title). Change connection")
            } else {
                Text(connection.title)
                    .font(.caption.bold())
                    .foregroundStyle(PearColor.textSecondary)
                    .accessibilityLabel("Logging to \(connection.title)")
            }
        }
    }

    private func button(for moment: WidgetFeed.AvailableMoment) -> some View {
        Button {
            onTap(moment)
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    if model.status == .logging(moment.id) {
                        ProgressView()
                    } else {
                        Text(moment.emoji).font(.system(size: 30))
                    }
                }
                .frame(height: 36)
                Text(moment.label)
                    .font(.caption2)
                    .foregroundStyle(PearColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 76)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 14))
        // Disabled only while a log is in flight: a second tap during the round
        // trip would log the moment twice, and the tray is small enough that the
        // first tap's spinner is easy to miss.
        .disabled(model.isBusy)
        .opacity(model.isBusy && model.status != .logging(moment.id) ? 0.4 : 1)
        .accessibilityLabel("Log \(moment.label)")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .idle, .logging:
            // Held open so the tray does not resize under the user's thumb when
            // a result arrives; Messages gives it very little height to start.
            Text(" ").font(.caption2)
        case .logged(let moment, let connection):
            // Names where it went. The old line said only "Beer logged", which
            // in an app where a moment can land in any of twenty connections is
            // half a sentence.
            Text(connection.isEmpty ? "\(moment) logged" : "\(moment) logged to \(connection)")
                .font(.caption2)
                .foregroundStyle(PearColor.accent)
                .lineLimit(1)
        case .failed:
            // Says what happened and what to do. The alternative — silence —
            // used to be paired with a message bubble claiming success.
            Text("Couldn't log that. Open Pear'd and try again.")
                .font(.caption2)
                .foregroundStyle(PearColor.error)
                .multilineTextAlignment(.center)
        }
    }
}
