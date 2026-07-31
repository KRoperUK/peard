import MessageUI
import SwiftUI

/// Who to reach and what to say, once "Invite" is tapped on a contacts match.
struct ComposeTarget: Identifiable {
    let id = UUID()
    let recipient: String
    let isPhone: Bool
    let message: String
}

/// Pre-addresses the invite to the matched contact's own phone or email —
/// native Messages/Mail compose where the device can send that way, falling
/// back to the general share sheet otherwise (an iPad with no phone number,
/// Mail never configured, or the Simulator, which can never send either).
struct InviteComposeView: View {
    let target: ComposeTarget
    let onFinish: () -> Void

    var body: some View {
        Group {
            if target.isPhone, MFMessageComposeViewController.canSendText() {
                MessageComposeView(recipient: target.recipient, body: target.message, onFinish: onFinish)
            } else if !target.isPhone, MFMailComposeViewController.canSendMail() {
                MailComposeView(recipient: target.recipient, subject: "Pear up on Pear'd 🍐", body: target.message, onFinish: onFinish)
            } else {
                ActivityView(activityItems: [target.message])
            }
        }
    }
}

private struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [recipient]
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}

private struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}
