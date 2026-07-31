import Foundation

/// Fixed marketing/legal URLs — unlike `PeardConfig`, these never vary by
/// build configuration: the privacy policy lives on the real domain even
/// when the app itself is pointed at a local dev server.
enum PeardLinks {
    static let privacyPolicy = URL(string: "https://peard.kroper.uk/privacy")!
}
