import PeardCore
import SwiftUI
import UIKit

/// A text field that opens on the emoji keyboard.
///
/// The custom-moment picker offered a grid of eight suggestions and a "use
/// another emoji" field. The field was the problem: focusing an ordinary
/// `TextField` opens whichever keyboard was last used, which is the alphabet,
/// so anything outside the eight suggestions meant knowing to hunt for the globe
/// key — and then the field's own filter threw away everything typed that was
/// not an emoji, including the moment mid-composition. In practice nothing could
/// be entered at all.
///
/// iOS has no public API for "open on the emoji keyboard". It does resolve
/// `textInputMode` per responder, though, and one of the modes offered to any
/// device has `primaryLanguage == "emoji"` — so a field that says that is the
/// mode it wants gets the emoji keyboard, and the globe key still works for
/// anybody who would rather search by name.
struct EmojiField: UIViewRepresentable {
    @Binding var emoji: String
    var isFocused: Bool

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiOnlyTextField()
        field.delegate = context.coordinator
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 34)
        field.tintColor = UIColor(PearColor.accent)
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartInsertDeleteType = .no
        // Nothing sensible follows a single emoji, so the return key just
        // dismisses.
        field.returnKeyType = .done
        field.text = emoji
        field.accessibilityLabel = "Moment emoji"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Only when it actually differs: assigning `text` moves the caret, and
        // doing that on every redraw fights whoever is typing.
        if field.text != emoji { field.text = emoji }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(emoji: $emoji) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let emoji: Binding<String>

        init(emoji: Binding<String>) {
            self.emoji = emoji
        }

        /// Keeps the last emoji typed and drops everything else, without ever
        /// emptying the field.
        ///
        /// The old version replaced the whole value on every keystroke and fell
        /// back to a pear when it found nothing it liked, so a stray character
        /// silently reset a chosen emoji. Here a non-emoji is simply refused:
        /// the field does not change, and the choice already made survives.
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Backspace. Allowed through so the field can be cleared and
            // retyped; the caller keeps the last non-empty value.
            if string.isEmpty { return true }
            guard let picked = MomentEmoji.first(in: string) else { return false }
            textField.text = picked
            emoji.wrappedValue = picked
            // Handled here, so `true` would insert it a second time.
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

/// A `UITextField` that asks for the emoji keyboard.
///
/// `textInputMode` is consulted by UIKit when the field becomes first responder.
/// Returning the emoji mode is the documented-enough trick every app that needs
/// this uses; if the device has no emoji mode — which would be unusual, but is
/// not impossible — it falls back to `super` and the globe key still gets there.
private final class EmojiOnlyTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
