import PeardCore
import SwiftUI

/// How long a tapped moment waits before it sends itself (#398).
///
/// The user's, not a connection's — it sits with Appearance and Low Data, the
/// other things in Settings that are about whoever is holding the phone. The
/// window is there so a note can be added after the tap; three seconds was too
/// short for that, so five is the default and the rest are for people who want
/// the tap-and-forget speed back or who write slower still.
struct SendWindowSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Picker("Send window", selection: Binding(
                get: { app.sendWindow },
                set: { app.sendWindow = $0 }
            )) {
                ForEach(SendWindow.allCases, id: \.self) { window in
                    Text(window.pickerTitle).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Send window")
        } header: {
            Text("Send window")
        } footer: {
            Text("How long a moment waits before it sends itself, so you can add a note. Typing a note holds the send until you tap Send.")
        }
    }
}
