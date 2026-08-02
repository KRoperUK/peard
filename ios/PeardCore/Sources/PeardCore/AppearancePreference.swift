import Foundation

/// Whether the app follows the system's light/dark setting or is pinned to one.
///
/// The palette has had light and dark variants of every colour since it was
/// built, so the app has always drawn correctly in either — it just had no
/// answer for somebody who wants dark while the rest of the phone stays light,
/// or the reverse. That is a real preference and not a redundant one: people
/// with light sensitivity often keep a dark interface in an otherwise light
/// system, and people who read at night in bed do the opposite.
///
/// `system` is the default and stays the default. Following the phone is what
/// almost everybody wants, and an app that decides for itself on first launch
/// is an app that ignores a setting somebody has already made once.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public static let `default` = AppearancePreference.system

    /// Tolerant of a value it does not recognise — a preference written by a
    /// later build, or a corrupted default, falls back to following the system
    /// rather than refusing to launch.
    public init(storedValue: String?) {
        self = AppearancePreference(rawValue: storedValue ?? "") ?? .default
    }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What the picker says underneath, so "System" does not need explaining
    /// twice.
    public var subtitle: String {
        switch self {
        case .system: return "Match your phone's appearance"
        case .light: return "Always light, whatever your phone does"
        case .dark: return "Always dark, whatever your phone does"
        }
    }
}
