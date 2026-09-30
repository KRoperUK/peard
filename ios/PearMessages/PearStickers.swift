import Messages
import SwiftUI

/// The sticker set: the Pear'd mark, drawn by ios/Tools/GenerateAppIcon.swift
/// alongside the app icons so the two cannot drift. Pears rather than the
/// moment emoji, because Apple's emoji cannot be shipped as sticker images.
enum PearStickers {
    struct Item: Identifiable {
        let name: String
        /// Read by VoiceOver, and shown where a sticker cannot be drawn.
        let description: String
        var id: String { name }
    }

    static let all: [Item] = [
        Item(name: "PearsOrchard", description: "Two green pears"),
        Item(name: "PearsAmber", description: "Two amber pears"),
        Item(name: "PearsBlush", description: "Two red pears"),
        Item(name: "PearsInk", description: "Two grey pears"),
        Item(name: "Pear", description: "A green pear"),
    ]

    static func sticker(_ item: Item) -> MSSticker? {
        guard let url = Bundle.main.url(forResource: item.name, withExtension: "png") else { return nil }
        return try? MSSticker(contentsOfFileURL: url, localizedDescription: item.description)
    }
}

/// One sticker, as Messages draws them: tap to put it in the compose field, or
/// press and drag to peel it onto a message.
struct StickerCell: UIViewRepresentable {
    let sticker: MSSticker

    func makeUIView(context: Context) -> MSStickerView {
        MSStickerView(frame: .zero, sticker: sticker)
    }

    func updateUIView(_ view: MSStickerView, context: Context) {
        view.sticker = sticker
    }
}

/// The picture on a moment's bubble: its emoji, large, on the app's cream.
/// Light whatever the sender's appearance, because it is drawn once and seen
/// in the other person's conversation, in theirs.
@MainActor
enum BubbleCard {
    static func image(emoji: String) -> UIImage? {
        let renderer = ImageRenderer(content: card(emoji: emoji))
        renderer.scale = 3
        return renderer.uiImage
    }

    private static func card(emoji: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(rgb: 0xFD_FA_F2), Color(rgb: 0xF1_E5_CB)],
                startPoint: .top,
                endPoint: .bottom
            )
            Text(emoji).font(.system(size: 88))
        }
        .frame(width: 300, height: 170)
    }
}
