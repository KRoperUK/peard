import CoreImage
import CoreImage.CIFilterBuiltins
import PeardCore
import SwiftUI
import UIKit

/// Turns a `PhotoEdit` into pixels.
///
/// Deliberately the only place that draws the final image, and it works from
/// the same `PhotoEdit` arithmetic the live preview uses — so what somebody
/// lined up in the editor is what gets sent, rather than two implementations of
/// "roughly centred" that drift apart.
enum PhotoSquare {
    /// What the square is rendered at. Big enough for a full-width photo on the
    /// largest phone at 3×, small enough that a JPEG of it is not an unpleasant
    /// thing to send from a train.
    static let side: CGFloat = 1080

    /// How hard the letterbox backdrop is blurred, in pixels at `side`.
    static let backdropBlur: CGFloat = 48

    /// Renders the edited photo as a square.
    static func render(_ image: UIImage, edit: PhotoEdit) -> UIImage {
        let side = PhotoSquare.side
        let format = UIGraphicsImageRendererFormat.default()
        // The maths is in pixels already, so a 3× scale here would render a
        // 3240px square from a 1080px plan.
        format.scale = 1
        format.opaque = true

        // Only a letterboxed photo leaves anything to see behind it, and the
        // blur is the expensive part of this — so it is not paid for by the
        // default case, which covers the square completely.
        let backdrop = edit.fit == .fit ? blurred(image) : nil

        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            // Under everything, so a blur that fails to render still leaves a
            // square rather than whatever was in the buffer.
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            if let backdrop {
                // Filled rather than fitted — the backdrop's whole job is to
                // leave no gap — and kept at the same rotation so a turned
                // photo does not sit on a backdrop pointing the other way.
                draw(backdrop, edit: PhotoEdit(fit: .fill, quarterTurns: edit.quarterTurns), side: side, in: context)
                // Held back so the photo in front of it stays the subject.
                UIColor.black.withAlphaComponent(0.25).setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }

            draw(image, edit: edit, side: side, in: context)
        }
    }

    /// Draws one image into the square according to an edit.
    ///
    /// Translate, rotate, then draw about the centre — the same order the
    /// preview's `.frame` / `.rotationEffect` / `.offset` produces, which is
    /// what keeps the two agreeing.
    private static func draw(
        _ image: UIImage,
        edit: PhotoEdit,
        side: CGFloat,
        in context: UIGraphicsImageRendererContext
    ) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = edit.scale(for: size, side: side)
        let offset = edit.clampedOffset(for: size, side: side)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)

        context.cgContext.saveGState()
        context.cgContext.translateBy(x: side / 2 + offset.width, y: side / 2 + offset.height)
        context.cgContext.rotate(by: CGFloat(edit.quarterTurns) * .pi / 2)
        image.draw(in: CGRect(
            x: -drawn.width / 2,
            y: -drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        ))
        context.cgContext.restoreGState()
    }

    /// A blurred copy, for the letterbox backdrop.
    ///
    /// Clamped before blurring and cropped back after, because a Gaussian on an
    /// unclamped image samples transparency past the edges and leaves a soft
    /// grey border — which, on a backdrop whose entire purpose is to fill the
    /// gap, is the one artefact that would show.
    private static func blurred(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        // Scaled to the photo, so a big photo is not blurred less than a small
        // one once both are squeezed into the same square.
        filter.radius = Float(backdropBlur * max(input.extent.width, input.extent.height) / side)

        let context = CIContext()
        guard
            let output = filter.outputImage?.cropped(to: input.extent),
            let cgImage = context.createCGImage(output, from: input.extent)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// The square, live, with the photo inside it and the gestures that move it.
///
/// iOS has no editor to present for an image that is not yet in the photo
/// library — `UIImagePickerController.allowsEditing` is the whole of what it
/// offers, and that is a forced square crop with no rotation and no way to keep
/// the edges. So this is the crop step, built from the native pieces:
/// `DragGesture` and `MagnifyGesture` for the framing, Core Image for the
/// backdrop, `UIGraphicsImageRenderer` for the result.
struct SquarePhotoEditor: View {
    let image: UIImage
    @Binding var edit: PhotoEdit

    /// In-flight gesture values, held apart from the committed edit so a pinch
    /// can rubber-band past the limit and settle back rather than fighting the
    /// finger all the way.
    @State private var liveZoom: CGFloat = 1
    @State private var liveOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                backdrop(side: side)
                photo(side: side)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .gesture(gestures(side: side))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        // One picture as far as VoiceOver is concerned. The controls beneath it
        // are what can actually be operated, and they say what they do.
        .accessibilityElement()
        .accessibilityLabel("The photo you just took")
        .accessibilityValue(edit.fit == .fill ? "Filling the square" : "Whole photo, padded")
    }

    /// Only ever seen around a letterboxed photo, and matched to the render so
    /// the preview is not prettier than the result.
    @ViewBuilder
    private func backdrop(side: CGFloat) -> some View {
        if edit.fit == .fit {
            let filled = layout(for: PhotoEdit(fit: .fill, quarterTurns: edit.quarterTurns), side: side)
            Image(uiImage: image)
                .resizable()
                .frame(width: filled.size.width, height: filled.size.height)
                .rotationEffect(.degrees(Double(edit.quarterTurns) * 90))
                .blur(radius: PhotoSquare.backdropBlur * side / PhotoSquare.side, opaque: true)
                .overlay(Color.black.opacity(0.25))
        } else {
            Color.black
        }
    }

    private func photo(side: CGFloat) -> some View {
        let shown = layout(for: live, side: side)
        return Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: shown.size.width, height: shown.size.height)
            .rotationEffect(.degrees(Double(edit.quarterTurns) * 90))
            .offset(shown.offset)
    }

    /// The committed edit with any in-flight gesture folded in.
    private var live: PhotoEdit {
        var value = edit
        value.zoom = edit.zoom * liveZoom
        value.offset = CGSize(
            width: edit.offset.width + liveOffset.width,
            height: edit.offset.height + liveOffset.height
        )
        return value
    }

    /// The size to draw at and where to put it. `rotationEffect` does not
    /// change layout, so the frame is the photo's own size scaled — the
    /// rotation happens about the centre and the clip does the rest.
    private func layout(for edit: PhotoEdit, side: CGFloat) -> (size: CGSize, offset: CGSize) {
        let scale = edit.scale(for: image.size, side: side)
        return (
            CGSize(width: image.size.width * scale, height: image.size.height * scale),
            edit.clampedOffset(for: image.size, side: side)
        )
    }

    /// Pan and pinch at once, because framing a photo is one movement — making
    /// it two would mean zooming, letting go, and finding the subject has left
    /// the square.
    private func gestures(side: CGFloat) -> some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard edit.fit == .fill else { return }
                    liveOffset = value.translation
                }
                .onEnded { _ in
                    guard edit.fit == .fill else { return }
                    // Committed already clamped, so the next drag starts from
                    // what is on screen rather than from somewhere off it.
                    edit.offset = live.clampedOffset(for: image.size, side: side)
                    liveOffset = .zero
                },
            MagnifyGesture()
                .onChanged { value in
                    guard edit.fit == .fill else { return }
                    liveZoom = value.magnification
                }
                .onEnded { _ in
                    guard edit.fit == .fill else { return }
                    edit.zoom = live.clampedZoom
                    // Zooming out can leave the pan past the new, smaller
                    // limit, which would show a gap until the next drag.
                    edit.offset = edit.clampedOffset(for: image.size, side: side)
                    liveZoom = 1
                }
        )
    }
}
