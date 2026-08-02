import Foundation

/// Which pear is on the home screen.
///
/// The same drawing in four hues rather than four designs: an alternate icon is
/// for somebody who wants their home screen to look like theirs, not a theme
/// gallery, and every extra one is three more PNGs to keep in step with
/// `ios/Tools/GenerateAppIcon.swift`, which draws them all.
public enum AppIconChoice: String, CaseIterable, Sendable {
    case orchard
    case amber
    case blush
    case ink

    public static let `default` = AppIconChoice.orchard

    /// The asset-catalogue name, and what `setAlternateIconName(_:)` is given.
    ///
    /// Nil for the default: UIKit takes nil to mean "back to the primary icon",
    /// and there is no alternate set named `AppIcon` to ask for — the primary is
    /// the primary.
    public var alternateName: String? {
        switch self {
        case .orchard: return nil
        case .amber: return "AppIconAmber"
        case .blush: return "AppIconBlush"
        case .ink: return "AppIconInk"
        }
    }

    /// Reads back what UIKit reports, which is the same nil-means-primary
    /// convention.
    public init(alternateName: String?) {
        guard let alternateName else {
            self = .orchard
            return
        }
        self = AppIconChoice.allCases.first { $0.alternateName == alternateName } ?? .orchard
    }

    public var title: String {
        switch self {
        case .orchard: return "Orchard"
        case .amber: return "Amber"
        case .blush: return "Blush"
        case .ink: return "Ink"
        }
    }

    /// Name of the preview image in the asset catalogue.
    ///
    /// A separate set from the icon itself: an `.appiconset` cannot be loaded
    /// as an `Image`, so the picker needs its own copy of the artwork. Drawn by
    /// the same generator from the same palette, so they cannot drift.
    public var previewAssetName: String {
        switch self {
        case .orchard: return "IconPreviewOrchard"
        case .amber: return "IconPreviewAmber"
        case .blush: return "IconPreviewBlush"
        case .ink: return "IconPreviewInk"
        }
    }
}
