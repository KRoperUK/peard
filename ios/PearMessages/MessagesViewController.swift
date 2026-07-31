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
    /// Drives the tray's spinner and its result line. Held here rather than in
    /// the view because the view is rebuilt from scratch on every update.
    private var status: MomentTrayView.Status = .idle {
        didSet { presentTray() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentTray()
    }

    private func presentTray() {
        let store = SharedStore.shared
        let isSignedIn = !(store.widgetToken ?? "").isEmpty && store.apiBaseURL != nil
        let tray = MomentTrayView(isSignedIn: isSignedIn, status: status) { [weak self] moment in
            self?.log(moment)
        }

        // Update the existing host in place where there is one. Tearing it down
        // and rebuilding on every status change would restart the transition and
        // drop the keyboard focus Messages hands the extension.
        if let hostingController {
            hostingController.rootView = tray
            return
        }

        let hosting = UIHostingController(rootView: tray)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    /// Logs the moment, then — only if the server took it — offers the bubble.
    ///
    /// The bubble used to go in regardless of the result, so a tap with no
    /// signal put a message reading "🍺 Beer logged" into a conversation with
    /// another person when nothing had been logged at all. Inserting it only on
    /// success means the thread never asserts something untrue, and the tray
    /// says what went wrong instead.
    private func log(_ moment: MomentTrayView.Moment) {
        guard case .idle = status else { return }
        status = .logging(moment.id)
        Task { @MainActor in
            let logged = await MomentLogging.perform(
                kind: moment.eventKind,
                pairID: nil,
                emoji: moment.emoji,
                label: moment.label
            )
            guard logged else {
                status = .failed
                return
            }
            status = .logged(moment.label)
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
                // Best effort — the moment is logged either way by this point;
                // only the visible acknowledgement in the thread is at stake.
                print("[PearMessages] could not insert bubble: \(error)")
            }
        }
    }
}
