import PeardCore
import PhotosUI
import SwiftUI
import UIKit

/// Turns a picked photo into avatar-sized JPEG bytes.
///
/// Resizing on the device rather than uploading the original is not an
/// optimisation: a modern iPhone photo is 3–6 MB and would be rejected by the
/// route's 8 MB ceiling often enough to be a bug, and it would be served to every
/// member of every connection to be drawn in a 46-point circle. 512 points square
/// is the largest thumbnail the migration declares, so anything bigger is bytes
/// nobody will ever see.
enum AvatarImage {
    /// The longest edge of the stored image, matching the `512x512` thumb.
    static let maxDimension: CGFloat = 512

    /// Square, centre-cropped, JPEG. Square because every place it is drawn is a
    /// circle or a squircle, and cropping here means the aspect ratio cannot
    /// surprise a layout later.
    static func jpegData(from image: UIImage, quality: CGFloat = 0.8) -> Data? {
        squareCropped(image).jpegData(compressionQuality: quality)
    }

    static func squareCropped(_ image: UIImage) -> UIImage {
        let side = maxDimension
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            // Scale to fill, then centre: the alternative, scale-to-fit, would
            // letterbox a portrait photo with bars inside the circle.
            let source = image.size
            guard source.width > 0, source.height > 0 else { return }
            let scale = max(side / source.width, side / source.height)
            let scaled = CGSize(width: source.width * scale, height: source.height * scale)
            image.draw(in: CGRect(
                x: (side - scaled.width) / 2,
                y: (side - scaled.height) / 2,
                width: scaled.width,
                height: scaled.height
            ))
        }
    }

    /// Reads a picked item and prepares it. Returns nil when the item carries no
    /// decodable image, which covers a picked video and an iCloud asset that could
    /// not be materialised.
    static func prepare(_ item: PhotosPickerItem) async -> Data? {
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
        else { return nil }
        return jpegData(from: image)
    }
}

/// A photo-picking row: the current avatar, a button to change it, and one to
/// remove it when there is something to remove.
///
/// Used for both a person and a connection, because the two differ only in what
/// happens on selection.
struct AvatarPickerRow: View {
    let avatar: Avatar
    let serverURL: URL
    let title: String
    let subtitle: String
    /// Nil when the subject has no photo of its own, so removal is not offered.
    let onRemove: (() async -> Void)?
    let onPick: (Data) async -> Void

    @State private var selection: PhotosPickerItem?
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AvatarView(avatar: avatar, serverURL: serverURL, size: 60, thumb: .large)
                    .overlay {
                        if isWorking {
                            Color.black.opacity(0.35)
                                .clipShape(Circle())
                                .overlay(ProgressView().tint(.white))
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PearColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                    Text(avatar.hasImage ? "Change photo" : "Add photo")
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.accent)
                }
                .disabled(isWorking)

                if let onRemove {
                    Button("Remove") {
                        Task {
                            isWorking = true
                            await onRemove()
                            isWorking = false
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(PearColor.error)
                    .disabled(isWorking)
                }
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(PearColor.error)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                isWorking = true
                failure = nil
                if let data = await AvatarImage.prepare(item) {
                    await onPick(data)
                } else {
                    failure = "That photo couldn't be read. Try another."
                }
                isWorking = false
                selection = nil
            }
        }
    }
}
