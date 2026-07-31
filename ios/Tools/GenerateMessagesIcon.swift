#!/usr/bin/env swift
//
// GenerateMessagesIcon.swift — derives the iMessage extension's icon set from
// the already-rendered app icon.
//
//   swift ios/Tools/GenerateMessagesIcon.swift          # or: make icons
//
// iMessage extension icons do not accept the single-size "universal" format
// the main AppIcon uses (Xcode 14+) — App Store Connect rejects the upload
// outright ("Missing App Icon... must be 148x110 pixels") without the classic
// explicit per-idiom, per-scale set. Rather than re-implementing the pear
// geometry for a handful of rectangular canvases, this loads the square
// AppIcon-1024.png GenerateAppIcon.swift already drew and pads it, aspect-fit
// and centred, onto each required size — same artwork, no duplicated
// drawing code to keep in sync.
//
// Sizes are Apple's iMessage set: the Messages drawer (27×20, 32×24), Settings
// (29×29), iPhone (60×45), iPad (67×50, 74×55) and the 1024×768 App Store
// marketing image.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // ios
    .appendingPathComponent("Peard/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")

private let outputDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    // .stickersiconset, not .appiconset. actool compiles this target with
    // `--stickers-icon-role extension`, which only looks inside a stickers icon
    // set; the same images in an .appiconset are parsed against the plain iOS
    // app-icon sizes, match none of them, and compile to nothing — with a
    // warning ("N unassigned children") rather than an error, so the build stays
    // green and the appex simply ships no icon.
    .appendingPathComponent("PearMessages/Assets.xcassets/iMessage App Icon.stickersiconset")

/// The cream background AppIcon-1024.png already bakes in, repeated here so
/// the padding around the source image reads as part of the same icon
/// rather than a visible seam.
private let backgroundTop: (r: CGFloat, g: CGFloat, b: CGFloat) = (0xFD / 255, 0xFA / 255, 0xF2 / 255)

private struct Target {
    let filename: String
    let width: Int
    let height: Int
}

private let targets: [Target] = [
    // Apple's full set, taken from Xcode's own Sticker Pack Extension template
    // (Platforms/iPhoneOS.platform/…/iMessage App Icon.stickersiconset). Copied
    // wholesale rather than trimmed to what a build warns about: App Store
    // Connect validates these one at a time, reporting the next missing size
    // only after the last one was fixed, so guessing costs an upload per guess.
    Target(filename: "iMessageAppIcon-29x29@2x.png", width: 58, height: 58),
    Target(filename: "iMessageAppIcon-29x29@3x.png", width: 87, height: 87),
    Target(filename: "iMessageAppIcon-ipad-29x29@2x.png", width: 58, height: 58),
    Target(filename: "iMessageAppIcon-27x20@2x.png", width: 54, height: 40),
    Target(filename: "iMessageAppIcon-27x20@3x.png", width: 81, height: 60),
    Target(filename: "iMessageAppIcon-32x24@2x.png", width: 64, height: 48),
    Target(filename: "iMessageAppIcon-32x24@3x.png", width: 96, height: 72),
    Target(filename: "iMessageAppIcon-60x45@2x.png", width: 120, height: 90),
    Target(filename: "iMessageAppIcon-60x45@3x.png", width: 180, height: 135),
    Target(filename: "iMessageAppIcon-67x50@2x.png", width: 134, height: 100),
    Target(filename: "iMessageAppIcon-74x55@2x.png", width: 148, height: 110),
    Target(filename: "iMessageAppIcon-1024x768@1x.png", width: 1024, height: 768),
]

guard
    let sourceData = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let source = CGImageSourceCreateImageAtIndex(sourceData, 0, nil)
else {
    fatalError("could not load \(sourceURL.path) — run GenerateAppIcon.swift first")
}

func render(width: Int, height: Int) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("could not create bitmap context")
    }

    context.setFillColor(red: backgroundTop.r, green: backgroundTop.g, blue: backgroundTop.b, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Aspect-fit the square source within 84% of the shorter side, centred —
    // the same kind of margin the main icon's own artwork leaves inside its
    // canvas, so the pear reads at a consistent size across every icon.
    let side = CGFloat(min(width, height)) * 0.84
    let originX = (CGFloat(width) - side) / 2
    let originY = (CGFloat(height) - side) / 2
    context.draw(source, in: CGRect(x: originX, y: originY, width: side, height: side))

    guard let image = context.makeImage() else { fatalError("could not snapshot the context") }
    return image
}

func write(_ image: CGImage, to url: URL) {
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

// The .appiconset is entirely derived — every PNG in it comes from this script
// — so creating it here means a deleted or never-created directory is not a
// crash halfway through the first write.
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for target in targets {
    let image = render(width: target.width, height: target.height)
    let url = outputDir.appendingPathComponent(target.filename)
    write(image, to: url)
    print("wrote \(target.filename) (\(target.width)x\(target.height))")
}
