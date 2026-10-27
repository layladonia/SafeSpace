import XCTest
@testable import SafeSpaceCore

final class ColorSpaceTests: XCTestCase {
    
    // these are for explicitly testing the algorithms (which shouldn't change)

    func testWhiteReferenceValueOKLab() {
        let white = ColorSpace.sRGBToOKLab(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.L, 1.0, accuracy: 0.001)
        XCTAssertEqual(white.a, 0.0, accuracy: 0.001)
        XCTAssertEqual(white.b, 0.0, accuracy: 0.001)
    }

    func testBlackReferenceValueOKLab() {
        let black = ColorSpace.sRGBToOKLab(r: 0, g: 0, b: 0)
        XCTAssertEqual(black.L, 0.0, accuracy: 0.001)
        XCTAssertEqual(black.a, 0.0, accuracy: 0.001)
        XCTAssertEqual(black.b, 0.0, accuracy: 0.001)
    }

    func testGrayReferenceValueOKLab() {
        let gray = ColorSpace.sRGBToOKLab(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertEqual(gray.L, 0.598, accuracy: 0.001)
        XCTAssertEqual(gray.a, 0.0, accuracy: 0.001)
        XCTAssertEqual(gray.b, 0.0, accuracy: 0.001)
    }

    func testRedReferenceValueOKLab() {
        let red = ColorSpace.sRGBToOKLab(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.L, 0.628, accuracy: 0.001)
        XCTAssertEqual(red.a, 0.225, accuracy: 0.001)
        XCTAssertEqual(red.b, 0.126, accuracy: 0.001)
    }

    func testWhiteReferenceValueCIELAB() {
        let white = ColorSpace.sRGBToCIELAB(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.L, 100.0, accuracy: 0.1)
        XCTAssertEqual(white.a, 0.0, accuracy: 0.1)
        XCTAssertEqual(white.b, 0.0, accuracy: 0.1)
    }

    func testBlackReferenceValueCIELAB() {
        let black = ColorSpace.sRGBToCIELAB(r: 0, g: 0, b: 0)
        XCTAssertEqual(black.L, 0.0, accuracy: 0.1)
        XCTAssertEqual(black.a, 0.0, accuracy: 0.1)
        XCTAssertEqual(black.b, 0.0, accuracy: 0.1)
    }

    func testGrayReferenceValueCIELAB() {
        let gray = ColorSpace.sRGBToCIELAB(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertEqual(gray.L, 53.389, accuracy: 0.1)
        XCTAssertEqual(gray.a, 0.0, accuracy: 0.1)
        XCTAssertEqual(gray.b, 0.0, accuracy: 0.1)
    }

    func testRedReferenceValueCIELAB() {
        let red = ColorSpace.sRGBToCIELAB(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.L, 53.241, accuracy: 0.1)
        XCTAssertEqual(red.a, 80.092, accuracy: 0.1)
        XCTAssertEqual(red.b, 67.203, accuracy: 0.1)
    }
}
