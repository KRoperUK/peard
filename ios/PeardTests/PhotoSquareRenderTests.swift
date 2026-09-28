import PeardCore
import UIKit
import XCTest
@testable import Peard

/// Rendering the sent square from a full-resolution capture (issue #1).
///
/// A 48MP photo is the realistic input — a phone's own camera — and the one the
/// simulator never produced from the library. Fit mode is the expensive case:
/// it blurs a backdrop behind the letterboxed photo.
final class PhotoSquareRenderTests: XCTestCase {
    /// 8064 × 6048, the size of a 48MP iPhone capture.
    private static let capture: UIImage = {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8064, height: 6048), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8064, height: 6048))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 2000, y: 1500, width: 4000, height: 3000))
        }
    }()

    func testAFullResolutionCaptureRendersToTheSquare() {
        let capture = Self.capture  // made before the clock starts
        let started = Date()
        let square = PhotoSquare.render(capture, edit: PhotoEdit(fit: .fit, quarterTurns: 0))
        let elapsed = Date().timeIntervalSince(started)
        print("PhotoSquare fit render of 48MP: \(String(format: "%.3f", elapsed))s")

        XCTAssertEqual(square.size, CGSize(width: PhotoSquare.side, height: PhotoSquare.side))
    }

    /// The render is called from a background task so the sheet stays live; it
    /// has to give the same answer there.
    func testRenderingOffTheMainActorGivesTheSameSquare() async {
        let image = Self.capture
        let edit = PhotoEdit(fit: .fit, quarterTurns: 1)
        let square = await Task.detached { PhotoSquare.render(image, edit: edit) }.value
        XCTAssertEqual(square.size, CGSize(width: PhotoSquare.side, height: PhotoSquare.side))
    }
}
