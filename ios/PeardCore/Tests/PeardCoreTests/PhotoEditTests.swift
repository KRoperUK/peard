import CoreGraphics
import Foundation
import Testing
@testable import PeardCore

/// The arithmetic behind the square crop step.
///
/// This is the part worth covering because it is the part that is shared: the
/// live preview and the final render both work from it, and a mistake here
/// shows up as "what I lined up is not what got sent" rather than as a crash.
@Suite("Squaring a photo up")
struct PhotoEditTests {
    /// A landscape photo — twice as wide as it is tall.
    private let landscape = CGSize(width: 4000, height: 2000)
    /// A portrait one, the other way round.
    private let portrait = CGSize(width: 2000, height: 4000)
    private let side: CGFloat = 1000

    // MARK: Defaults

    @Test("A photo nobody has touched fills the square")
    func defaultsToFill() {
        #expect(PhotoEdit.identity.fit == .fill)
        #expect(PhotoEdit.identity.quarterTurns == 0)
        #expect(PhotoEdit.identity.isIdentity)
    }

    // MARK: Fill

    @Test("Filling scales by the short edge, so nothing is left uncovered")
    func fillCoversTheSquare() {
        let edit = PhotoEdit(fit: .fill)
        // The short edge is 2000; covering a 1000 square needs 0.5.
        #expect(edit.scale(for: landscape, side: side) == 0.5)
        // Which leaves the long edge at 2000 — twice the square.
        #expect(landscape.width * edit.scale(for: landscape, side: side) == 2000)
    }

    @Test("Filling leaves room to pan along the long edge only")
    func fillPansOnTheLongEdgeOnly() {
        let limit = PhotoEdit(fit: .fill).panLimit(for: landscape, side: side)
        // 2000 wide in a 1000 square: 500 spare each way.
        #expect(limit.width == 500)
        // And nothing spare vertically — it only just covers.
        #expect(limit.height == 0)
    }

    @Test("A pan cannot open a gap at the edge")
    func panIsClamped() {
        let edit = PhotoEdit(fit: .fill, offset: CGSize(width: 9000, height: 40))
        let clamped = edit.clampedOffset(for: landscape, side: side)
        #expect(clamped.width == 500)
        // Vertically there was never anywhere to go.
        #expect(clamped.height == 0)
    }

    @Test("Zooming in makes more room to pan")
    func zoomWidensTheLimits() {
        let plain = PhotoEdit(fit: .fill).panLimit(for: landscape, side: side)
        let zoomed = PhotoEdit(fit: .fill, zoom: 2).panLimit(for: landscape, side: side)
        #expect(zoomed.width > plain.width)
        // Doubling the scale doubles the photo: 4000 wide, 1500 spare each way.
        #expect(zoomed.width == 1500)
        // And the short edge now has room too, where before it had none.
        #expect(zoomed.height == 500)
    }

    @Test("Zooming out below a full square is not allowed")
    func zoomCannotShrinkBelowFill() {
        // A pinch that ran the other way would otherwise open a gap.
        let edit = PhotoEdit(fit: .fill, zoom: 0.2)
        #expect(edit.clampedZoom == 1)
        #expect(edit.scale(for: landscape, side: side) == 0.5)
    }

    @Test("Zoom stops somewhere short of pure pixels")
    func zoomIsCapped() {
        #expect(PhotoEdit(fit: .fill, zoom: 99).clampedZoom == PhotoEdit.maximumZoom)
    }

    // MARK: Fit

    @Test("Fitting scales by the long edge, so no edge is lost")
    func fitKeepsTheWholePhoto() {
        let edit = PhotoEdit(fit: .fit)
        // The long edge is 4000; fitting it in 1000 needs 0.25.
        #expect(edit.scale(for: landscape, side: side) == 0.25)
        // Leaving the short edge at 500 — half the square, padded either side.
        #expect(landscape.height * edit.scale(for: landscape, side: side) == 500)
    }

    @Test("A fitted photo has nowhere to pan, because it is all already shown")
    func fitDoesNotPan() {
        let edit = PhotoEdit(fit: .fit, offset: CGSize(width: 400, height: 400))
        #expect(edit.panLimit(for: landscape, side: side) == .zero)
        #expect(edit.clampedOffset(for: landscape, side: side) == .zero)
    }

    @Test("Zoom does not apply to a fitted photo")
    func fitIgnoresZoom() {
        // Zooming a letterboxed photo would crop it, which is the thing
        // letterboxing was picked to avoid.
        let edit = PhotoEdit(fit: .fit, zoom: 3)
        #expect(edit.scale(for: landscape, side: side) == 0.25)
    }

    // MARK: Rotation

    @Test("A turn swaps which edge is long")
    func rotationSwapsTheEdges() {
        let upright = PhotoEdit(quarterTurns: 0)
        let turned = PhotoEdit(quarterTurns: 1)
        #expect(upright.orientedSize(of: landscape) == landscape)
        #expect(turned.orientedSize(of: landscape) == portrait)
    }

    @Test("A turned landscape photo fills the square the way a portrait one does")
    func rotationChangesTheFit() {
        let turned = PhotoEdit(fit: .fill, quarterTurns: 1)
        let limit = turned.panLimit(for: landscape, side: side)
        // Turned on its side it is 2000 tall in a 1000 square, so the spare
        // room has moved from the horizontal to the vertical.
        #expect(limit.width == 0)
        #expect(limit.height == 500)
    }

    @Test("Four turns is where it started")
    func rotationWrapsAround() {
        var edit = PhotoEdit.identity
        for _ in 0..<4 { edit.rotate() }
        #expect(edit.quarterTurns == 0)
    }

    @Test("Turning recentres, because a pan framed the old orientation")
    func rotationResetsThePan() {
        var edit = PhotoEdit(fit: .fill, offset: CGSize(width: 300, height: 0))
        edit.rotate()
        #expect(edit.offset == .zero)
    }

    @Test("A turn given as a negative or an overshoot still lands in range")
    func quarterTurnsAreNormalised() {
        #expect(PhotoEdit(quarterTurns: -1).quarterTurns == 3)
        #expect(PhotoEdit(quarterTurns: 7).quarterTurns == 3)
        #expect(PhotoEdit(quarterTurns: 4).quarterTurns == 0)
    }

    // MARK: Degenerate input

    @Test("A photo with no size does not divide by zero")
    func zeroSizedImageIsSurvivable() {
        let edit = PhotoEdit(fit: .fill)
        #expect(edit.scale(for: .zero, side: side) == 1)
        #expect(edit.panLimit(for: .zero, side: side) == .zero)
    }

    @Test("A square of no size does not divide by zero")
    func zeroSidedSquareIsSurvivable() {
        #expect(PhotoEdit(fit: .fill).scale(for: landscape, side: 0) == 1)
    }

    // MARK: The square itself

    @Test("A square photo needs no crop either way")
    func aSquarePhotoIsUnchanged() {
        let square = CGSize(width: 2000, height: 2000)
        #expect(PhotoEdit(fit: .fill).scale(for: square, side: side) == 0.5)
        #expect(PhotoEdit(fit: .fit).scale(for: square, side: side) == 0.5)
        #expect(PhotoEdit(fit: .fill).panLimit(for: square, side: side) == .zero)
    }
}
