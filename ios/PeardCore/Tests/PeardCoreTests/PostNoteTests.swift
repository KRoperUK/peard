import Foundation
import Testing
@testable import PeardCore

@Suite("Post notes and captions")
struct PostNoteTests {
    @Test("The limit is the server's, not a number of our own")
    func limitMatchesTheServer() {
        // server/internal/posts/posts.go: maxNoteLength = 280, and the posts
        // collection's `note` field is Max: 280. If either moves, this fails
        // here rather than as a 400 on somebody's phone.
        #expect(PostNote.limit == 280)
    }

    // MARK: While typing

    @Test("Capping leaves ordinary text alone")
    func cappingIsANoOpBelowTheLimit() {
        #expect(PostNote.capped("the dog, finally still") == "the dog, finally still")
    }

    @Test("Capping stops at the limit rather than refusing later")
    func cappingTruncates() {
        let long = String(repeating: "a", count: 400)
        #expect(PostNote.capped(long).count == 280)
    }

    @Test("Capping keeps the space that was just typed")
    func cappingDoesNotTrim() {
        // Trimming on every keystroke would delete the space between words as
        // soon as it was typed, which reads as a broken keyboard.
        #expect(PostNote.capped("at the pub ") == "at the pub ")
    }

    @Test("Capping counts characters, not bytes")
    func cappingCountsCharacters() {
        // An emoji is several bytes and one character. Cutting by bytes could
        // land mid-scalar and produce a replacement character.
        let emoji = String(repeating: "🍐", count: 300)
        let capped = PostNote.capped(emoji)
        #expect(capped.count == 280)
        #expect(capped.hasSuffix("🍐"))
    }

    // MARK: On the way out

    @Test("Sending trims the edges")
    func normalisingTrims() {
        #expect(PostNote.normalised("  at the pub \n") == "at the pub")
    }

    @Test("Whitespace alone is the same as saying nothing")
    func whitespaceOnlyBecomesEmpty() {
        #expect(PostNote.normalised("   \n\t ") == "")
        #expect(PostNote.isEmpty("   \n\t "))
    }

    @Test("Nothing typed is nothing sent")
    func emptyStaysEmpty() {
        #expect(PostNote.normalised("") == "")
        #expect(PostNote.isEmpty(""))
    }

    @Test("Real words are not empty")
    func textIsNotEmpty() {
        #expect(!PostNote.isEmpty(" a "))
    }

    @Test("Sending never hands the server more than it accepts")
    func normalisingCaps() {
        // Padded so trimming happens first — trim-then-cap and cap-then-trim
        // differ when the padding is what pushes it over.
        let long = "  " + String(repeating: "a", count: 400) + "  "
        #expect(PostNote.normalised(long).count == 280)
    }
}
