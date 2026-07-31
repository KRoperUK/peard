import Foundation

/// Fixed marketing/legal URLs — unlike `PeardConfig`, these never vary by
/// build configuration: the privacy policy lives on the real domain even
/// when the app itself is pointed at a local dev server.
enum PeardLinks {
    static let privacyPolicy = URL(string: "https://peard.kroper.uk/privacy")!
    /// The address the privacy policy gives for deletion and data requests.
    /// Kept in step with `contactEmail` in `server/internal/site/site.go` by
    /// hand — it is shown to somebody whose in-app attempt has just failed, so
    /// a stale one would be a dead end at the worst moment.
    static let supportEmail = "kieran@kroper.uk"
}
