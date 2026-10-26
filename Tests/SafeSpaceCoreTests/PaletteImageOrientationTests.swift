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
        XCTAssertEqual(output.provenance.workingCopy.resizeMethod, "area_average_gamma_encoded")
    }
    func testShrinkAveragesEverySourcePixel() throws {
        // 1-pixel black/white checkerboard; a 2x shrink must give mid-gray, not sampled black or white
        var rgba: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<2048 { rgba += (x + y) % 2 == 0 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
        }
        let output = try ImageLoader.load(data: SRGBImage(width: 2048, height: 4, rgba: rgba).pngData(), source: .library)
        XCTAssertEqual(output.image.width, 1024)
        XCTAssertEqual(output.image.height, 2)
        let red = stride(from: 0, to: output.image.rgba.count, by: 4).map { output.image.rgba[$0] }
        XCTAssertEqual(Set(red), [128])
    }
    func testOutOfRangeOrientationIsTreatedAsUpright() {
        // ImageIO rewrites 0 as 1 when saving, so this checks the mapping directly
        XCTAssertEqual(ImageLoader.uprightOrientation(0), 1)
        XCTAssertEqual(ImageLoader.uprightOrientation(9), 1)
        XCTAssertEqual(ImageLoader.uprightOrientation(nil), 1)
        XCTAssertEqual(ImageLoader.uprightOrientation(6), 6)
    }
    func testPixelBoundsClampBoxesPastTheEdge() {
        let past = NormalizedRect(x: 0.8, y: 0.5, width: 0.2000001, height: 0.6)
        XCTAssertTrue(past.pixelBounds(width: 10, height: 10) == (8, 5, 10, 10))
        let empty = NormalizedRect(x: 0.5, y: 0.5, width: -0.2, height: 0.1)
        let bounds = empty.pixelBounds(width: 10, height: 10)
        XCTAssertEqual(bounds.x0, bounds.x1)
        let mask = EligibilityMask.all(width: 10, height: 10).excluding([past, empty])
        XCTAssertEqual(mask.eligibleCount, 100 - 10)
    }
}
