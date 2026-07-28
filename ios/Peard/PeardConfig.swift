import Foundation
import PeardCore

/// Build-time configuration, resolved from Info.plist keys that are populated
/// from `Config.xcconfig` (Requirement 3).
struct PeardConfig: Sendable {
    /// Used when the configured value is missing or unusable (Requirement 3.2).
    static let fallbackServerURL = PeardServerURL.fallback

    let serverURL: URL
    let googleClientID: String

    static let current = PeardConfig.load()

    static func load(bundle: Bundle = .main) -> PeardConfig {
        PeardConfig(
            serverURL: PeardServerURL.resolve(bundle.object(forInfoDictionaryKey: "PeardServerURL") as? String),
            googleClientID: (bundle.object(forInfoDictionaryKey: "PeardGoogleIOSClientID") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    var hasGoogleClientID: Bool { !googleClientID.isEmpty }

    /// Message shown when Google sign-in is attempted without a client id
    /// (Requirement 3.4).
    static let missingGoogleClientIDMessage = "Set the Google iOS client id in the build configuration first"
}
