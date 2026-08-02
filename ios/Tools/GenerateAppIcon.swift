#!/usr/bin/env swift
//
// GenerateAppIcon.swift — draws the Pear'd app icon into AppIcon.appiconset.
//
//   swift ios/Tools/GenerateAppIcon.swift          # or: make icons
//
// Two overlapping pears (the "pair"), separated by a seam in the background
// colour so the silhouettes stay readable when the icon is 40pt on a home
// screen. Colours come from PearPalette (PeardCore/PearPalette.swift).
//
// Three variants are written, per Apple's light/dark/tinted app-icon support:
//
//   AppIcon-1024.png         opaque, no alpha  — required, also the App Store
//                                                marketing icon
//   AppIcon-1024-Dark.png    colour + alpha    — the system supplies the dark
//                                                background
//   AppIcon-1024-Tinted.png  greyscale + alpha — the system supplies the
//                                                background and the tint
//
// No external dependencies: CoreGraphics and ImageIO ship with the OS, so this
// stays consistent with the project's no-prebuild-step rule.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// A pear drawn in normalised units: the fruit is 1.0 tall, sits on y = 0 and is
/// centred on x = 0. The stem and leaf reach up to about y = 1.25.
private enum Pear {
    static func fruit() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        // Right side, bottom to top: bulb, waist, shoulder.
        path.addCurve(
            to: CGPoint(x: 0.42, y: 0.32),
            control1: CGPoint(x: 0.30, y: 0.0),
            control2: CGPoint(x: 0.42, y: 0.14)
        )
        path.addCurve(
            to: CGPoint(x: 0.21, y: 0.70),
            control1: CGPoint(x: 0.42, y: 0.52),
            control2: CGPoint(x: 0.29, y: 0.60)
        )
        path.addCurve(
            to: CGPoint(x: 0.0, y: 1.0),
            control1: CGPoint(x: 0.145, y: 0.82),
            control2: CGPoint(x: 0.125, y: 1.0)
        )
        // Mirrored left side, top back down to the base.
        path.addCurve(
            to: CGPoint(x: -0.21, y: 0.70),
            control1: CGPoint(x: -0.125, y: 1.0),
            control2: CGPoint(x: -0.145, y: 0.82)
        )
        path.addCurve(
            to: CGPoint(x: -0.42, y: 0.32),
            control1: CGPoint(x: -0.29, y: 0.60),
            control2: CGPoint(x: -0.42, y: 0.52)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: -0.42, y: 0.14),
            control2: CGPoint(x: -0.30, y: 0.0)
        )
        path.closeSubpath()
        return path
    }

    /// The stem, as a stroked centreline converted to a fillable outline.
    static func stem() -> CGPath {
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 0.0, y: 0.94))
        line.addQuadCurve(to: CGPoint(x: 0.06, y: 1.20), control: CGPoint(x: -0.01, y: 1.09))
        return line.copy(strokingWithWidth: 0.055, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    static func leaf() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.055, y: 1.10))
        path.addCurve(
            to: CGPoint(x: 0.32, y: 1.23),
            control1: CGPoint(x: 0.15, y: 1.19),
            control2: CGPoint(x: 0.24, y: 1.25)
        )
        path.addCurve(
            to: CGPoint(x: 0.055, y: 1.10),
            control1: CGPoint(x: 0.26, y: 1.13),
            control2: CGPoint(x: 0.17, y: 1.07)
        )
        path.closeSubpath()
        return path
    }
}

/// One pear's placement on the canvas, in normalised-to-canvas terms.
private struct Placement {
    let centreX: CGFloat  // fraction of canvas width
    let baseY: CGFloat    // fraction of canvas height
    let scale: CGFloat    // fraction of canvas height per normalised unit
    let rotation: CGFloat // degrees, positive is anticlockwise

    func transform(canvas: CGFloat, fit: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform.identity
            .concatenating(CGAffineTransform(scaleX: scale * canvas, y: scale * canvas))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: centreX * canvas, y: baseY * canvas))
            .concatenating(fit)
    }
}

private struct PearShapes {
    /// The fruit and the stem are filled separately: as subpaths of one path
    /// their winding directions oppose, and the overlap cancels out.
    let fruit: CGPath
    let stem: CGPath
    let leaf: CGPath?
    /// fruit + stem + leaf, used to punch the seam behind the front pear.
    let silhouette: CGPath
}

private func shapes(
    for placement: Placement,
    canvas: CGFloat,
    fit: CGAffineTransform,
    withLeaf: Bool
) -> PearShapes {
    let t = placement.transform(canvas: canvas, fit: fit)

    let fruit = CGMutablePath()
    fruit.addPath(Pear.fruit(), transform: t)

    let stem = CGMutablePath()
    stem.addPath(Pear.stem(), transform: t)

    let leaf = withLeaf ? CGMutablePath() : nil
    leaf?.addPath(Pear.leaf(), transform: t)

    let silhouette = CGMutablePath()
    silhouette.addPath(fruit)
    silhouette.addPath(stem)
    if let leaf { silhouette.addPath(leaf) }

    return PearShapes(fruit: fruit, stem: stem, leaf: leaf, silhouette: silhouette)
}

// MARK: - Composition

private let backPear = Placement(centreX: 0.60, baseY: 0.26, scale: 0.40, rotation: -7)
private let frontPear = Placement(centreX: 0.41, baseY: 0.17, scale: 0.45, rotation: 6)

/// Fraction of the canvas the artwork should span. iOS masks the icon to a
/// squircle, so the mark is kept inside a generous margin.
private let contentFraction: CGFloat = 0.78

private struct Palette {
    let background: (top: UInt32, bottom: UInt32)?  // nil means transparent
    let backBody: UInt32
    let backStemLeaf: UInt32
    let frontBody: UInt32
    let frontLeaf: UInt32
    let seam: UInt32?  // nil means erase to transparency
    let opaque: Bool

    /// A complete set for one icon: the three appearances Apple asks for.
    ///
    /// Alternate icons are the same drawing in a different hue, so a family is
    /// four colours and a ground rather than a whole new palette — which is the
    /// only reason offering several is cheap.
    struct Family {
        /// The asset-catalogue name. The default one is "AppIcon"; the rest are
        /// what `setAlternateIconName(_:)` is given.
        let assetName: String
        /// What the picker calls it.
        let title: String
        let light: Palette
        let dark: Palette
        let tinted: Palette

        /// Tinted is greyscale in every family — the system supplies the tint,
        /// so hue here would be thrown away. Shared rather than repeated.
        static let sharedTinted = Palette(
            background: nil,
            backBody: 0x8A_8A_8A,
            backStemLeaf: 0x6E_6E_6E,
            frontBody: 0xF2_F2_F2,
            frontLeaf: 0xC8_C8_C8,
            seam: nil,
            opaque: false
        )

        static func make(
            assetName: String,
            title: String,
            ground: (top: UInt32, bottom: UInt32),
            seam: UInt32,
            lightBack: UInt32, lightBackStem: UInt32, lightFront: UInt32, lightFrontLeaf: UInt32,
            darkBack: UInt32, darkBackStem: UInt32, darkFront: UInt32, darkFrontLeaf: UInt32
        ) -> Family {
            Family(
                assetName: assetName,
                title: title,
                light: Palette(
                    background: ground,
                    backBody: lightBack,
                    backStemLeaf: lightBackStem,
                    frontBody: lightFront,
                    frontLeaf: lightFrontLeaf,
                    seam: seam,
                    opaque: true
                ),
                dark: Palette(
                    background: nil,
                    backBody: darkBack,
                    backStemLeaf: darkBackStem,
                    frontBody: darkFront,
                    frontLeaf: darkFrontLeaf,
                    seam: nil,
                    opaque: false
                ),
                tinted: sharedTinted
            )
        }
    }

    /// Light: warm cream ground, PearAccent-family greens.
    static let light = Palette(
        background: (top: 0xFD_FA_F2, bottom: 0xF1_E5_CB),
        backBody: 0x4C_6B_1C,
        backStemLeaf: 0x3F_5A_16,
        frontBody: 0x7C_A5_2B,
        frontLeaf: 0x9B_BF_4F,
        seam: 0xFB_F7_EC,
        opaque: true
    )

    /// Dark: dark-mode accent greens over transparency. Apple permits baking a
    /// custom dark background in instead, but iOS 26's Liquid Glass pass uses
    /// the alpha channel to separate artwork from backdrop, and an opaque
    /// background makes it composite the mark against a stray light shape.
    static let dark = Palette(
        background: nil,
        backBody: 0x5A_7A_28,
        backStemLeaf: 0x49_63_20,
        frontBody: 0x9B_BF_4F,
        frontLeaf: 0xB8_D6_74,
        seam: nil,
        opaque: false
    )

    /// Tinted: greyscale over transparency; the system tints and backs it.
    /// The system maps luminance onto the chosen tint, so the front leaf is
    /// darker than the front body rather than lighter — at 0xFF it would be
    /// indistinguishable from a near-white body.
    static let tinted = Palette(
        background: nil,
        backBody: 0x8A_8A_8A,
        backStemLeaf: 0x6E_6E_6E,
        frontBody: 0xF2_F2_F2,
        frontLeaf: 0xC8_C8_C8,
        seam: nil,
        opaque: false
    )
}

private func components(_ rgb: UInt32) -> [CGFloat] {
    [
        CGFloat((rgb >> 16) & 0xFF) / 255,
        CGFloat((rgb >> 8) & 0xFF) / 255,
        CGFloat(rgb & 0xFF) / 255,
        1,
    ]
}

private func render(palette: Palette, side: Int) -> CGImage {
    let canvas = CGFloat(side)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha: CGImageAlphaInfo = palette.opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: alpha.rawValue
    ) else {
        fatalError("could not create a \(side)x\(side) bitmap context")
    }

    // Measure the artwork at identity, then scale and centre it so the two
    // pears together fill `contentFraction` of the canvas.
    let measured = CGMutablePath()
    measured.addPath(shapes(for: backPear, canvas: canvas, fit: .identity, withLeaf: true).silhouette)
    measured.addPath(shapes(for: frontPear, canvas: canvas, fit: .identity, withLeaf: true).silhouette)
    let box = measured.boundingBoxOfPath
    let fitScale = contentFraction * canvas / max(box.width, box.height)
    let fit = CGAffineTransform(scaleX: fitScale, y: fitScale)
        .concatenating(CGAffineTransform(
            translationX: (canvas - box.width * fitScale) / 2 - box.minX * fitScale,
            y: (canvas - box.height * fitScale) / 2 - box.minY * fitScale
        ))

    let back = shapes(for: backPear, canvas: canvas, fit: fit, withLeaf: true)
    let front = shapes(for: frontPear, canvas: canvas, fit: fit, withLeaf: true)

    if let background = palette.background {
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(colorSpace: space, components: components(background.top))!,
                CGColor(colorSpace: space, components: components(background.bottom))!,
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: canvas),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    func fill(_ path: CGPath, _ rgb: UInt32) {
        context.addPath(path)
        context.setFillColor(CGColor(colorSpace: space, components: components(rgb))!)
        context.fillPath()
    }

    // Back pear first, then a seam around the front pear, then the front pear.
    fill(back.fruit, palette.backBody)
    fill(back.stem, palette.backStemLeaf)
    if let leaf = back.leaf { fill(leaf, palette.backStemLeaf) }

    // The seam only has a job where the two pears overlap, so it is clipped to
    // the back pear. Unclipped it would ring the front pear against the
    // background gradient, which reads as a stray outline.
    context.saveGState()
    context.addPath(back.silhouette)
    context.clip()
    if let seam = palette.seam {
        context.setStrokeColor(CGColor(colorSpace: space, components: components(seam))!)
    } else {
        // No background to draw the seam in, so cut it out instead.
        context.setBlendMode(.destinationOut)
        context.setStrokeColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
    }
    context.setLineWidth(canvas * 0.022)
    context.setLineJoin(.round)
    context.addPath(front.silhouette)
    context.strokePath()
    context.restoreGState()

    fill(front.fruit, palette.frontBody)
    fill(front.stem, palette.frontBody)
    if let leaf = front.leaf { fill(leaf, palette.frontLeaf) }

    guard let image = context.makeImage() else { fatalError("could not snapshot the context") }
    return image
}

// MARK: - Output

private func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

// ios/Tools/GenerateAppIcon.swift -> ios/Peard/Assets.xcassets/AppIcon.appiconset
private let iconSet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // ios
    .appendingPathComponent("Peard/Assets.xcassets/AppIcon.appiconset")

/// Writes the Contents.json that binds the three PNGs to their appearances.
///
/// Generated rather than committed by hand: an alternate icon that is missing
/// one appearance fails at build time with a message about the asset
/// catalogue, not about the icon, and three sets of it is three chances to get
/// that wrong.
private func writeContents(for family: Palette.Family, in set: URL) {
    let json = """
    {
      "images" : [
        {
          "filename" : "\(family.assetName)-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "filename" : "\(family.assetName)-1024-Dark.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "tinted"
            }
          ],
          "filename" : "\(family.assetName)-1024-Tinted.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try? json.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

/// Writes a normal image set of the same artwork, for the picker.
///
/// An `.appiconset` cannot be loaded as an `Image` at runtime — it is compiled
/// into icon slots, not into a named asset — so a picker showing what you are
/// choosing needs its own copy. Drawn here from the same palette in the same
/// pass, which is the only way the two cannot drift.
///
/// Light appearance only, and small: it is a thumbnail in a settings row, and
/// the dark/tinted variants are the system's business rather than something to
/// preview.
private func writePreview(for family: Palette.Family) {
    let name = "IconPreview" + family.title
    let set = iconSet
        .deletingLastPathComponent()
        .appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    for scale in [1, 2, 3] {
        let file = "\(name)@\(scale)x.png"
        write(render(palette: family.light, side: 120 * scale), to: set.appendingPathComponent(file))
    }

    let json = """
    {
      "images" : [
        { "filename" : "\(name)@1x.png", "idiom" : "universal", "scale" : "1x" },
        { "filename" : "\(name)@2x.png", "idiom" : "universal", "scale" : "2x" },
        { "filename" : "\(name)@3x.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
    try? json.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(name).imageset")
}

// The icons somebody can choose between.
//
// The first is the real one — its asset set is `AppIcon`, which is what the app
// falls back to and what the App Store shows. The rest are alternates, named in
// project.yml's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES and selected at
// runtime with `setAlternateIconName(_:)`.
//
// Deliberately few, and all obviously the same mark. An alternate icon is for
// somebody who wants their home screen to look like theirs, not a theme gallery
// — and every one added is three more PNGs to keep in step with the drawing.
private let families: [Palette.Family] = [
    Palette.Family(
        assetName: "AppIcon",
        title: "Orchard",
        light: .light,
        dark: .dark,
        tinted: Palette.Family.sharedTinted
    ),
    // A pear left on the windowsill a week longer.
    Palette.Family.make(
        assetName: "AppIconAmber",
        title: "Amber",
        ground: (top: 0xFF_F6_E4, bottom: 0xF6_E0_B8),
        seam: 0xFD_F3_E0,
        lightBack: 0xB0_6E_12, lightBackStem: 0x8E_57_0D,
        lightFront: 0xE0_9A_25, lightFrontLeaf: 0xF2_BC_57,
        darkBack: 0xA9_6C_18, darkBackStem: 0x8A_56_12,
        darkFront: 0xE8_A8_3C, darkFrontLeaf: 0xF7_CB_79
    ),
    // The blush on a ripe red pear.
    Palette.Family.make(
        assetName: "AppIconBlush",
        title: "Blush",
        ground: (top: 0xFF_F1_F0, bottom: 0xF7_D9_D6,),
        seam: 0xFD_EE_EC,
        lightBack: 0x9E_2F_36, lightBackStem: 0x7E_25_2B,
        lightFront: 0xCB_4A_4A, lightFrontLeaf: 0xE3_78_71,
        darkBack: 0x97_33_38, darkBackStem: 0x79_28_2C,
        darkFront: 0xD8_5C_58, darkFrontLeaf: 0xEE_8F_88
    ),
    // For a home screen that would rather the app did not shout.
    Palette.Family.make(
        assetName: "AppIconInk",
        title: "Ink",
        ground: (top: 0x2C_2A_27, bottom: 0x1A_18_15),
        seam: 0x23_21_1E,
        lightBack: 0x6F_6B_63, lightBackStem: 0x57_54_4D,
        lightFront: 0xC8_C3_B8, lightFrontLeaf: 0xE6_E1_D6,
        darkBack: 0x6F_6B_63, darkBackStem: 0x57_54_4D,
        darkFront: 0xC8_C3_B8, darkFrontLeaf: 0xE6_E1_D6
    ),
]

for family in families {
    let set = iconSet
        .deletingLastPathComponent()
        .appendingPathComponent("\(family.assetName).appiconset")
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    let appearances: [(suffix: String, palette: Palette)] = [
        ("", family.light),
        ("-Dark", family.dark),
        ("-Tinted", family.tinted),
    ]
    for appearance in appearances {
        let name = "\(family.assetName)-1024\(appearance.suffix).png"
        write(render(palette: appearance.palette, side: 1024), to: set.appendingPathComponent(name))
        print("wrote \(family.assetName)/\(name)")
    }
    writeContents(for: family, in: set)
    writePreview(for: family)
}
