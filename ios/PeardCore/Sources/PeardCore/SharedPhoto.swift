import CoreGraphics
import Foundation
import ImageIO

/// Reads a photo handed to the share extension at no more than the size it
/// will be sent at.
///
/// A share extension runs in a memory budget of roughly 120 MB, and a 48 MP
/// photo decoded whole is nearly 200 MB of pixels — the extension would be
/// killed before it drew anything. ImageIO can decode straight to a smaller
/// size without ever holding the full image, which is what this does.
///
/// Also applies the photo's EXIF orientation, so a portrait shot from the
/// camera is not squared on its side.
public enum SharedPhoto {
    /// The image at `url`, no longer than `maxPixelSize` on its long edge.
    /// Smaller images come back at their own size, not enlarged.
    public static func downsampled(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsampled(source, maxPixelSize: maxPixelSize)
    }

    /// The same, from data already in memory — how some apps share an image.
    public static func downsampled(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsampled(source, maxPixelSize: maxPixelSize)
    }

    /// Not cached on creation: caching is the full-size decode this exists to
    /// avoid.
    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    private static func downsampled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
