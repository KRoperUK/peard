import SwiftUI

/// Bridges the system share sheet for the one place SwiftUI's `ShareLink`
/// doesn't fit: sharing a file that has to be fetched and written to disk
/// asynchronously first, rather than being available the moment the control
/// is created.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
