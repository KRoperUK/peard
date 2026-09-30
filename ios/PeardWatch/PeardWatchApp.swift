import PeardCore
import SwiftUI

@main
struct PeardWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase
    private let receiver = WatchSessionReceiver()

    var body: some Scene {
        WindowGroup {
            MomentGridView(model: model)
                .task {
                    receiver.onChange = { [model] in Task { await model.load() } }
                    receiver.activate()
                    await model.load()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    receiver.requestIfMissing()
                    Task { await model.load() }
                }
        }
    }
}
