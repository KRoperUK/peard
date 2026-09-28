import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PeardCore

/// Reading a shared photo at the size it will be sent at, so a full-resolution
/// camera photo never has to fit in the share extension's memory.
final class SharedPhotoTests: XCTestCase {
    private func jpeg(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testALargePhotoComesBackNoLongerThanTheLimit() throws {
        let image = try XCTUnwrap(SharedPhoto.downsampled(try jpeg(width: 4000, height: 3000), maxPixelSize: 2160))

        XCTAssertEqual(image.width, 2160)
        XCTAssertEqual(image.height, 1620)
    }

    /// Enlarging would only make a bigger file of the same detail.
    func testASmallPhotoIsNotEnlarged() throws {
        let image = try XCTUnwrap(SharedPhoto.downsampled(try jpeg(width: 800, height: 600), maxPixelSize: 2160))

        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 600)
    }

    /// A portrait camera photo is stored landscape with an orientation flag.
    /// Ignoring the flag would square it on its side.
    func testTheOrientationIsApplied() throws {
        let rotated = try jpeg(width: 400, height: 200, orientation: 6)

        let image = try XCTUnwrap(SharedPhoto.downsampled(rotated, maxPixelSize: 2160))

        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 400)
    }

    func testAFileIsReadTheSameWay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).jpg")
        try jpeg(width: 3000, height: 4000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try XCTUnwrap(SharedPhoto.downsampled(at: url, maxPixelSize: 1000))

        XCTAssertEqual(image.width, 750)
        XCTAssertEqual(image.height, 1000)
    }

    func testSomethingThatIsNotAnImageGivesNothing() {
        XCTAssertNil(SharedPhoto.downsampled(Data("not a photo".utf8), maxPixelSize: 2160))
    }
}
