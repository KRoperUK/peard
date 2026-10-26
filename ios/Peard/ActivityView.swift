import SwiftUI

/// A file waiting in a sheet, identifiable so the sheet presents from the
/// value itself (`sheet(item:)`) rather than from a hand-rolled optional
/// check. A URL is not `Identifiable`, so this wraps the one the export
/// wrote.
struct ShareableFile: Identifiable {
    let url: URL
    var id: URL { url }
}

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
