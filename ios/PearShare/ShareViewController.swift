import SwiftUI
import UIKit

/// The share extension's entry point: hosts `ShareView` and hands it the
/// shared items.
///
/// A plain `UIViewController` rather than `SLComposeServiceViewController`,
/// whose single text field and fixed layout have no room for a connection and
/// a moment.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = ShareView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSent: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        )
        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await model.load(from: attachments) }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
