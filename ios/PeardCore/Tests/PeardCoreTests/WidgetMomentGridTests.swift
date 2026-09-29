import XCTest
@testable import PeardCore

final class WidgetMomentGridTests: XCTestCase {
    func testAFullCatalogueIsCutToFourRowsOfFive() {
        XCTAssertEqual(WidgetMomentGrid.columns(isAccessibilitySize: false), 5)
        XCTAssertEqual(WidgetMomentGrid.shown(Array(1 ... 60), isAccessibilitySize: false), Array(1 ... 20))
    }

    func testAShortCatalogueIsShownWhole() {
        XCTAssertEqual(WidgetMomentGrid.shown(Array(1 ... 7), isAccessibilitySize: false), Array(1 ... 7))
    }

    func testAccessibilitySizesGetTwoRowsOfFourWiderCells() {
        XCTAssertEqual(WidgetMomentGrid.columns(isAccessibilitySize: true), 4)
        XCTAssertEqual(WidgetMomentGrid.shown(Array(1 ... 60), isAccessibilitySize: true), Array(1 ... 8))
    }
}
