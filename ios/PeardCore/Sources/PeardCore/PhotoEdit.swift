import CoreGraphics
import Foundation

/// How a photo is fitted into the square it is shared as.
public enum PhotoFit: String, CaseIterable, Codable, Sendable {
    /// Fills the square and crops what hangs over the edges. The default,
    /// because a photo taken to show something is usually of the middle of
    /// itself, and a full-bleed square is what the timeline and the widgets
    /// are laid out for.
    case fill
    /// Fits the whole photo inside the square and pads the rest. Nothing is
    /// lost — which matters for the pictures where the point is at the edge:
    /// a whole pint glass, a whiteboard, a sign.
    case fit
}

/// A non-destructive description of how a photo should be squared up.
///
/// The camera's own `allowsEditing` crop is the only editor iOS hands to third
/// parties, and it does exactly one thing: crop to a square, no rotation, no
/// way to keep the whole frame. So the step is ours, and this is the part of it
/// worth testing — the arithmetic that decides what ends up inside the square.
/// It holds no pixels, which is what lets the same values drive the live
/// preview and the final render and be sure the two agree.
public struct PhotoEdit: Equatable, Sendable {
    /// Crop or letterbox.
    public var fit: PhotoFit
    /// Rotation in 90° steps, clockwise. Phones get photos upside down often
    /// enough — and a picture taken sideways of something that is not sideways
    /// is not worth re-taking.
    public var quarterTurns: Int
    /// A multiplier on top of whatever `fit` already requires, so 1 is
    /// "exactly filled" and never smaller. Only meaningful when filling: a
    /// letterboxed photo is already showing all of itself.
    public var zoom: CGFloat
    /// How far the photo is pushed from centre, in points of the square.
    public var offset: CGSize

    public init(
        fit: PhotoFit = .fill,
        quarterTurns: Int = 0,
        zoom: CGFloat = 1,
        offset: CGSize = .zero
    ) {
        self.fit = fit
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.zoom = zoom
        self.offset = offset
    }

    /// Nothing done to it yet.
    public static let identity = PhotoEdit()

    /// Whether this would change the picture at all, so a photo nobody edited
    /// can skip the re-encode and keep its original quality.
    public var isIdentity: Bool { self == .identity }

    // MARK: Rotation

    /// A quarter turn clockwise.
    public mutating func rotate() {
        quarterTurns = (quarterTurns + 1) % 4
        // Panning is in the square's coordinates, not the photo's, so an
        // offset that framed a face before the turn frames nothing after it.
        // Recentring is less surprising than carrying the old pan through.
        offset = .zero
    }

    /// The photo's size once turned — width and height swap on the odd turns.
    public func orientedSize(of imageSize: CGSize) -> CGSize {
        quarterTurns % 2 == 0
            ? imageSize
            : CGSize(width: imageSize.height, height: imageSize.width)
    }

    // MARK: Fitting

    /// How much the photo is scaled to sit in a square of this side.
    ///
    /// Filling takes the larger ratio so no gap can appear; fitting takes the
    /// smaller so no edge is lost. `zoom` is only applied to the former,
    /// because zooming a letterboxed photo would crop it — which is the thing
    /// letterboxing was chosen to avoid.
    public func scale(for imageSize: CGSize, side: CGFloat) -> CGFloat {
        let size = orientedSize(of: imageSize)
        guard size.width > 0, size.height > 0, side > 0 else { return 1 }
        let horizontal = side / size.width
        let vertical = side / size.height
        switch fit {
        case .fill:
            return max(horizontal, vertical) * clampedZoom
        case .fit:
            return min(horizontal, vertical)
        }
    }

    /// How far the photo may be pushed before a gap opens at an edge.
    ///
    /// Zero on an axis the photo only just covers, which is why a portrait
    /// photo slides up and down but not side to side: there is nothing spare
    /// to slide.
    public func panLimit(for imageSize: CGSize, side: CGFloat) -> CGSize {
        guard fit == .fill else { return .zero }
        let size = orientedSize(of: imageSize)
        let scale = scale(for: imageSize, side: side)
        return CGSize(
            width: max(0, (size.width * scale - side) / 2),
            height: max(0, (size.height * scale - side) / 2)
        )
    }

    /// The offset actually applied, held inside the limits.
    ///
    /// Clamping on read rather than on write means a drag can run past the edge
    /// and come back without the gesture having thrown the excess away, and a
    /// change of fit or rotation cannot leave a stale offset showing a gap.
    public func clampedOffset(for imageSize: CGSize, side: CGFloat) -> CGSize {
        let limit = panLimit(for: imageSize, side: side)
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }

    /// The zoom actually applied. Below 1 a gap would open, and above a point
    /// there is nothing left to see but pixels.
    public var clampedZoom: CGFloat {
        min(max(zoom, 1), PhotoEdit.maximumZoom)
    }

    public static let maximumZoom: CGFloat = 4
}
