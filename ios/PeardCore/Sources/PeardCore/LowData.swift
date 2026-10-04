import Foundation

/// Whether the app holds back on data, and who decides (issue #302).
///
/// `automatic` follows iOS: Low Data Mode is a per-network switch in Settings,
/// and the system reports it as a *constrained* path. That is the right default
/// — somebody who has turned it on for their phone plan has already said what
/// they want, once, for every app. The other two exist because the system
/// switch is per network and blunt: somebody on a capped hotspot that iOS does
/// not know is capped wants it on, and somebody who turned it on for one app's
/// sake may not want it here.
///
/// Global, not per connection. It is a property of the phone's data plan, and
/// nobody's plan is cheaper for one group than another.
public enum LowDataPreference: String, CaseIterable, Sendable {
    case automatic
    case on
    case off

    public static let `default` = LowDataPreference.automatic

    /// Tolerant of a value it does not recognise, like `AppearancePreference`:
    /// a setting written by a later build falls back to following the system.
    public init(storedValue: String?) {
        self = LowDataPreference(rawValue: storedValue ?? "") ?? .default
    }

    /// Whether to behave as low-data right now, given what the network says.
    public func isActive(systemConstrained: Bool) -> Bool {
        switch self {
        case .automatic: return systemConstrained
        case .on: return true
        case .off: return false
        }
    }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    public var subtitle: String {
        switch self {
        case .automatic:
            return "Follows Low Data Mode in iOS Settings: smaller photos and no background refresh while it's on."
        case .on:
            return "Always use smaller photos and skip background refresh, whatever the network."
        case .off:
            return "Full-size photos and background refresh, even when iOS Low Data Mode is on."
        }
    }
}

/// The sizes a shared photo is fetched at.
///
/// Only sizes the `posts.media` field declares exist on the server; asking for
/// any other makes PocketBase serve the original, which is the very thing
/// these are here to avoid.
public enum PhotoThumb: String, CaseIterable, Sendable {
    case small = "256x256"
    case medium = "512x512"
    case large = "1024x1024"

    /// For a row or the hero card, drawn at 36 and 72 points. 256 is still
    /// more than 72 points at 3x; 512 is what they have always had.
    public static func list(lowData: Bool) -> PhotoThumb {
        lowData ? .small : .medium
    }

    /// For the full-screen viewer. Nil is the original upload, which is
    /// several megabytes of camera photo — worth it when data is cheap, and
    /// one tap away ("Load full photo") when it is not.
    public static func viewer(lowData: Bool) -> PhotoThumb? {
        lowData ? .large : nil
    }
}
