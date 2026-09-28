import ActivityKit
import PeardCore
import SwiftUI
import UIKit
import WidgetKit

/// The photo-drop Live Activity: who shared the latest photo in a connection,
/// what they said about it, and how many have arrived in the last half hour.
///
/// Started and updated by the server; nothing here asks for data. The photo is
/// shown only if the notification service extension has already cached it —
/// the activity has no network — and a 📸 stands in until then.
struct PhotoDropLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhotoDropAttributes.self) { context in
            PhotoDropLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(PearColor.background)
                .activitySystemActionForegroundColor(PearColor.accent)
                .widgetURL(URL(string: "peard://home"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhotoDropThumbnail(postID: context.state.postID, size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        Text(PhotoDropCopy.line(for: context.state)).font(.caption).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.count > 1 {
                        Text("\(context.state.count)").font(.title3.bold()).monospacedDigit()
                    }
                }
            } compactLeading: {
                Text("📸")
            } compactTrailing: {
                Text("\(context.state.count)").monospacedDigit()
            } minimal: {
                Text("📸")
            }
            .widgetURL(URL(string: "peard://home"))
        }
    }
}

private struct PhotoDropLockScreenView: View {
    let attributes: PhotoDropAttributes
    let state: PhotoDropAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            PhotoDropThumbnail(postID: state.postID, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.title)
                    .font(.headline)
                    .foregroundStyle(PearColor.textPrimary)
                    .lineLimit(1)
                Text(PhotoDropCopy.line(for: state))
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
                    .lineLimit(2)
                if state.count > 1 {
                    Text("\(state.count) photos in the last half hour")
                        .font(.caption)
                        .foregroundStyle(PearColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Text(state.updated, style: .relative)
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 64, alignment: .trailing)
        }
        .padding(14)
        .opacity(isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// The cached thumbnail, or a 📸 when the extension has not saved it yet.
private struct PhotoDropThumbnail: View {
    let postID: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url = PhotoDropCache.url(forPost: postID),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("📸")
                    .font(.system(size: size * 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PearColor.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

enum PhotoDropCopy {
    static func line(for state: PhotoDropAttributes.ContentState) -> String {
        state.caption.isEmpty
            ? "\(state.authorName) shared a photo"
            : "\(state.authorName): \(state.caption)"
    }
}

#Preview("Lock Screen", as: .content, using: PhotoDropAttributes(pairID: "pair1", title: "Flatmates")) {
    PhotoDropLiveActivity()
} contentStates: {
    PhotoDropAttributes.ContentState(postID: "none", authorName: "Ada", caption: "", count: 1, updatedAt: Date().timeIntervalSince1970 - 60)
    PhotoDropAttributes.ContentState(postID: "none", authorName: "Bo", caption: "the view from up here", count: 3, updatedAt: Date().timeIntervalSince1970 - 300)
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: PhotoDropAttributes(pairID: "pair1", title: "Flatmates")) {
    PhotoDropLiveActivity()
} contentStates: {
    PhotoDropAttributes.ContentState(postID: "none", authorName: "Bo", caption: "the view from up here", count: 3, updatedAt: Date().timeIntervalSince1970 - 300)
}
