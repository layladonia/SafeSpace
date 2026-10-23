import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SafeSpaceCore

final class PaletteImageOrientationTests: XCTestCase {
    func testAllEightEXIFOrientations() throws {
        let shades: [UInt8] = [20, 50, 80, 110, 140, 170]
        let bytes = shades.flatMap { [$0, $0, $0, UInt8(255)] }
        let base = SRGBImage(width: 2, height: 3, rgba: bytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(base.pngData() as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let orders = [[0,1,2,3,4,5], [1,0,3,2,5,4], [5,4,3,2,1,0], [4,5,2,3,0,1],
                      [0,2,4,1,3,5], [4,2,0,5,3,1], [5,3,1,4,2,0], [1,3,5,0,2,4]]
        for orientation in 1...8 {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let loaded = try ImageLoader.load(data: data as Data, source: .library).image
            XCTAssertEqual(loaded.width, orientation >= 5 ? 3 : 2)
            XCTAssertEqual(loaded.height, orientation >= 5 ? 2 : 3)
            let red = stride(from: 0, to: loaded.rgba.count, by: 4).map { loaded.rgba[$0] }
            XCTAssertEqual(red, orders[orientation - 1].map { shades[$0] }, "Orientation \(orientation)")
        }
    }
    func testResizeIsBounded() throws {
        let input = SRGBImage(width: 2048, height: 2, rgba: Array(repeating: [UInt8(255),0,0,255], count: 4096).flatMap { $0 })
        let output = try ImageLoader.load(data: input.pngData(), source: .library)
        XCTAssertEqual(output.image.width, 1024)
        XCTAssertEqual(output.image.height, 1)
        XCTAssertEqual(output.provenance.original.width, 2048)
        XCTAssertEqual(output.provenance.workingCopy.resizeMethod, "bilinear_gamma_encoded")
    }
}
