import Foundation

/// Moments somebody has pinned to the front of the grid (issue #11).
///
/// Pinned rather than sorted by use: the grid's value is muscle memory, and a
/// grid that reorders itself by the tallies moves under the thumb. Pins are
/// explicit and stay put. Per connection, because a group's moments are not a
/// pair's, and per device, because where a thumb reaches is too.
public enum MomentPins {
    /// Pinned moments first, in the order they were pinned, then the rest in
    /// their usual order. A pin for a moment the connection no longer offers is
    /// skipped rather than shown.
    public static func ordered(_ moments: [Moment], pinned: [String]) -> [Moment] {
        let bySlug = Dictionary(moments.map { ($0.kind.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let front = pinned.compactMap { bySlug[$0] }
        let frontSlugs = Set(front.map(\.kind.rawValue))
        return front + moments.filter { !frontSlugs.contains($0.kind.rawValue) }
    }

    /// Pins `slug` at the end of the pinned run, or unpins it.
    public static func toggled(_ slug: String, in pinned: [String]) -> [String] {
        pinned.contains(slug) ? pinned.filter { $0 != slug } : pinned + [slug]
    }
}
