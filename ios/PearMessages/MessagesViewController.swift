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
        model.offer(Self.bubble(selectedIn: conversation))
        Task { @MainActor in await model.load() }
    }

    /// A bubble tapped while the tray is already open.
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        model.offer(Self.bubble(selectedIn: conversation))
    }

    /// The moment in the bubble the tray was opened from — somebody else's
    /// only. Your own bubble offering "log one too" would log the same moment
    /// twice.
    private static func bubble(selectedIn conversation: MSConversation) -> MomentBubble? {
        guard
            let message = conversation.selectedMessage,
            message.senderParticipantIdentifier != conversation.localParticipantIdentifier
        else { return nil }
        return MomentBubble(url: message.url)
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
            if model.offered?.kind == moment.kind { model.offer(nil) }
            insertBubble(for: moment)
        }
    }

    private func insertBubble(for moment: WidgetFeed.AvailableMoment) {
        guard let conversation = activeConversation else { return }
        let bubble = MomentBubble(kind: moment.kind, emoji: moment.emoji, label: moment.label)
        let message = MSMessage()
        let layout = MSMessageTemplateLayout()
        layout.image = BubbleCard.image(emoji: moment.emoji)
        layout.caption = bubble.caption
        layout.subcaption = MomentBubble.subcaption
        layout.trailingCaption = Date().formatted(date: .omitted, time: .shortened)
        // Deliberately not the connection's name. The tray says where the moment
        // went because that is for the person who logged it; the bubble goes
        // into a thread with somebody who may not be in that connection at all,
        // and naming it there would tell them something about who else you share
        // with.
        message.layout = layout
        // What a notification or the conversation list shows for it.
        message.summaryText = bubble.caption
        // Carries the moment for "log one too", and opens the site on a device
        // without the extension. See MomentBubble for why only the moment.
        if let base = SharedStore.shared.apiBaseURL {
            message.url = bubble.url(base: base)
        }
        conversation.insert(message) { error in
            if let error {
                // Best effort — the moment is logged either way by this point;
                // only the visible acknowledgement in the thread is at stake.
                print("[PearMessages] could not insert bubble: \(error)")
            }
        }
    }
}
