import Foundation
import PeardCore

/// Build-time configuration, resolved from Info.plist keys that are populated
/// from the configuration's xcconfig — Config.debug.xcconfig or
/// Config.release.xcconfig, either of which a git-ignored Config.xcconfig can
/// override (Requirement 3).
struct PeardConfig: Sendable {
    /// Used when the configured value is missing or unusable (Requirement 3.2).
    ///
    /// Per configuration, because a single fallback cannot serve both: the
    /// localhost default is what a developer wants when Config.xcconfig is
    /// half-filled, and is unreachable — and refused by App Transport
    /// Security — in a distributed build. A Release build that somehow loses
    /// its Info.plist value should still talk to the real server.
    #if DEBUG
    static let fallbackServerURL = PeardServerURL.fallback
    #else
    static let fallbackServerURL = URL(string: "https://peard.kroper.uk")!
    #endif

    let serverURL: URL
    let googleClientID: String

    static let current = PeardConfig.load()

    static func load(bundle: Bundle = .main) -> PeardConfig {
        let configured = bundle.object(forInfoDictionaryKey: "PeardServerURL") as? String
        #if DEBUG
        let serverURL = DebugSupport.serverURLOverride ?? configured
        #else
        let serverURL = configured
        #endif
        return PeardConfig(
            serverURL: PeardServerURL.resolve(serverURL, fallback: fallbackServerURL),
            googleClientID: (bundle.object(forInfoDictionaryKey: "PeardGoogleIOSClientID") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    var hasGoogleClientID: Bool { !googleClientID.isEmpty }

    /// Message shown when Google sign-in is attempted without a client id
    /// (Requirement 3.4).
    static var missingGoogleClientIDMessage: String {
        String(localized: "Set the Google iOS client id in the build configuration first")
    }
}
