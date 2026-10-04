import PeardCore
import SwiftUI

/// Marks a post as an answer to a photo, with the photo beside it.
///
/// A comment or a photo sent back is an ordinary row in the timeline, so on
/// its own "lovely!" would read as a remark about nothing. The chip says what
/// it is about, and the thumbnail is the quickest way to say which photo:
/// tapping it opens that photo in the viewer.
///
/// The photo may not be one the screen has — it can be a page further back, or
/// still being fetched — and then the chip says "a photo" without a picture
/// rather than holding the row up.
struct ReplyChip: View {
    let original: Post?
    let title: String
    let serverURL: URL
    let onOpen: (Post) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .imageScale(.small)
            if let original, let path = original.mediaThumbnailPath() {
                ProtectedImage(serverURL: serverURL, path: path) {
                    Color.clear
                } failure: {
                    Text("📷").font(.caption2)
                }
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2.bold())
        .foregroundStyle(PearColor.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(PearColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(PearColor.divider))
        .contentShape(Capsule())
        .onTapGesture {
            if let original, original.hasMedia { onOpen(original) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    /// "replying to Ada's photo", "replying to your photo", or "replying to a
    /// photo" when the photo is not to hand.
    static func title(for original: Post?, signedInUserID: String, authorLabel: (Post) -> String) -> String {
        guard let original else { return "replying to a photo" }
        if original.author == signedInUserID { return "replying to your photo" }
        return "replying to \(authorLabel(original))'s photo"
    }
}
