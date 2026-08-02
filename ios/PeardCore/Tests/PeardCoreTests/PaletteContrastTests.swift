import SwiftUI
import XCTest
@testable import PeardCore

/// Every text/background pair in the palette, measured.
///
/// Written because the palette shipped failing: white on the dark-mode accent
/// was 2.11:1 — below even the 3:1 bar for large text, on the primary button of
/// every screen — and tertiary text in light mode was 2.22:1 across 27 captions.
/// Both were invisible to review and obvious to a formula, which is the sort of
/// thing a test should own.
final class PaletteContrastTests: XCTestCase {
    /// WCAG AA for body text. The stricter of the two thresholds is used
    /// throughout rather than allowing 3:1 for large text: which sizes a colour
    /// ends up drawn at is not a property of the colour, and the palette is
    /// reused freely.
    private let minimumRatio = 4.5

    private func ratio(_ a: PearColor.Swatch, _ b: PearColor.Swatch) -> Double {
        let hi = max(a.luminance, b.luminance)
        let lo = min(a.luminance, b.luminance)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func assertReadable(
        _ foreground: PearColor.Swatch,
        on background: PearColor.Swatch,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = ratio(foreground, background)
        XCTAssertGreaterThanOrEqual(
            value, minimumRatio,
            String(format: "%@ is %.2f:1, needs %.1f:1", what, value, minimumRatio),
            file: file, line: line
        )
    }

    func testTextIsReadableInLight() {
        let swatches = PearColor.swatches(dark: false)
        for (name, colour) in swatches.textColours {
            assertReadable(colour, on: swatches.background, "light \(name) on background")
            assertReadable(colour, on: swatches.surface, "light \(name) on surface")
        }
    }

    func testTextIsReadableInDark() {
        let swatches = PearColor.swatches(dark: true)
        for (name, colour) in swatches.textColours {
            assertReadable(colour, on: swatches.background, "dark \(name) on background")
            assertReadable(colour, on: swatches.surface, "dark \(name) on surface")
        }
    }

    /// The one that was worst, and the one that matters most: it is the label on
    /// "Share a photo", "Save" and "Add and send".
    func testTheAccentButtonLabelIsReadable() {
        for dark in [false, true] {
            let swatches = PearColor.swatches(dark: dark)
            assertReadable(
                swatches.onAccent, on: swatches.accent,
                "\(dark ? "dark" : "light") button label on accent"
            )
        }
    }

    /// White is what it used to be, and is why this test exists.
    func testWhiteOnTheDarkAccentWouldStillFail() {
        let dark = PearColor.swatches(dark: true)
        let white = PearColor.Swatch(red: 1, green: 1, blue: 1)

        XCTAssertLessThan(
            ratio(white, dark.accent), minimumRatio,
            "if this passes, the dark accent changed and onAccent may no longer be needed"
        )
    }
}
