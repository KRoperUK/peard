import Messages
import PeardCore
import SwiftUI
import UIKit

/// The iMessage app: a compact tray reachable from the Messages app drawer
/// rather than the home screen, for the moments that need no per-connection
/// lookup — same three as the widget and Siri.
///
/// Tapping a moment logs it immediately, the same way the widget's own
/// buttons do (LogMomentIntent, already shared via PeardCore), and only then
/// pre-loads a bubble into the conversation's compose field. Apple does not
/// let an extension send a message on somebody's behalf — insert(_:) fills
/// the compose bar, it does not tap Send — so logging first means the moment
/// is never lost even if the bubble is discarded.
final class MessagesViewController: MSMessagesAppViewController {
    private var hostingController: UIHostingController<MomentTrayView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        presentTray()
    }

    private func presentTray() {
        if let hostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }

        let store = SharedStore.shared
        let isSignedIn = !(store.widgetToken ?? "").isEmpty && store.apiBaseURL != nil
        let tray = MomentTrayView(isSignedIn: isSignedIn) { [weak self] moment in
            self?.log(moment)
        }

        let hosting = UIHostingController(rootView: tray)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    private func log(_ moment: MomentTrayView.Moment) {
        Task {
            let intent = LogMomentIntent(kind: moment.eventKind, pairID: nil, emoji: moment.emoji, label: moment.label)
            _ = try? await intent.perform()
            insertBubble(for: moment)
        }
    }

    private func insertBubble(for moment: MomentTrayView.Moment) {
        guard let conversation = activeConversation else { return }
        let message = MSMessage()
        let layout = MSMessageTemplateLayout()
        layout.caption = "\(moment.emoji) \(moment.label) logged"
        message.layout = layout
        conversation.insert(message) { error in
            if let error {
                // Best effort — the moment is already logged either way; only
                // the visible acknowledgement in the thread is at stake here.
                print("[PearMessages] could not insert bubble: \(error)")
            }
        }
    }
}
