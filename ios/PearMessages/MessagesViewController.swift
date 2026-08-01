import Messages
import PeardCore
import SwiftUI
import UIKit

/// The iMessage app: a tray reachable from the Messages app drawer rather than
/// the home screen, for logging a moment without leaving the conversation.
///
/// Tapping a moment logs it immediately, the same way the widget's own buttons
/// do (LogMomentIntent, already shared via PeardCore), and only then pre-loads a
/// bubble into the conversation's compose field. Apple does not let an extension
/// send a message on somebody's behalf — insert(_:) fills the compose bar, it
/// does not tap Send — so logging first means the moment is never lost even if
/// the bubble is discarded.
final class MessagesViewController: MSMessagesAppViewController {
    private var hostingController: UIHostingController<MomentTrayView>?
    private let model = MomentTrayModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        presentTray()
        Task { @MainActor in await model.load() }
    }

    /// Reloads when the tray is opened again.
    ///
    /// Messages keeps the extension alive between presentations, so without this
    /// a connection joined since the last time — or a moment published in one —
    /// would not appear until the whole extension was evicted.
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        Task { @MainActor in await model.load() }
    }

    private func presentTray() {
        let tray = MomentTrayView(model: model) { [weak self] moment in
            self?.log(moment)
        }

        // Update the existing host in place where there is one. Tearing it down
        // and rebuilding would restart the transition and drop the keyboard
        // focus Messages hands the extension. The tray observes the model, so
        // this only ever runs once in practice.
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
    /// success means the thread never asserts something untrue.
    private func log(_ moment: WidgetFeed.AvailableMoment) {
        Task { @MainActor in
            guard await model.log(moment) else { return }
            insertBubble(for: moment)
        }
    }

    private func insertBubble(for moment: WidgetFeed.AvailableMoment) {
        guard let conversation = activeConversation else { return }
        let message = MSMessage()
        let layout = MSMessageTemplateLayout()
        layout.caption = "\(moment.emoji) \(moment.label) logged"
        // Deliberately not the connection's name. The tray says where the moment
        // went because that is for the person who logged it; the bubble goes
        // into a thread with somebody who may not be in that connection at all,
        // and naming it there would tell them something about who else you share
        // with.
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
