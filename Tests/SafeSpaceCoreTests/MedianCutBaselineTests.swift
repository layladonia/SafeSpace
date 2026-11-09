import XCTest
@testable import SafeSpaceCore

final class MedianCutBaselineTests: XCTestCase {
    private func image(_ pixels: [[UInt8]]) -> SRGBImage {
        SRGBImage(width: pixels.count, height: 1, rgba: pixels.flatMap { $0 + [255] })
    }
    private var params: PaletteParams {
        var p = PaletteParams.v1
        p.kInitial = 2; p.mergeDeltaEOk = 0; p.minShare = 0
        return p
    }
    func testBothMethodsUseSameInterfaceAndPreserveCounts() throws {
        let input = image([[255,0,0], [255,0,0], [255,0,0], [0,0,255]])
        let mask = EligibilityMask.all(width: 4, height: 1)
        for method in [PaletteMethod.kmeansPP, .medianCut] {
            let output = try makePaletteExtractor(method).extract(input, mask: mask, params: params)
            XCTAssertEqual(output.result.colors.count, 2)
            XCTAssertEqual(output.result.colors.map(\.pixelCount), [3,1])
            XCTAssertEqual(output.result.colors.map(\.share), [0.75,0.25])
            XCTAssertEqual(output.result.droppedShare, 0)
            for (index, color) in output.result.colors.enumerated() {
                XCTAssertEqual(output.labelMap.filter { $0 == UInt8(index) }.count, color.pixelCount)
            }
        }
    }
    func testMedianCutWeightedCentroid() throws {
        let input = image([[0,0,0], [0,0,0], [0,0,0], [255,255,255]])
        var p = params; p.kInitial = 1
        let output = try MedianCut().extract(input, mask: .all(width: 4, height: 1), params: p)
        let white = ColorSpace.sRGBToOKLab(r: 1, g: 1, b: 1)
        XCTAssertEqual(output.result.colors[0].oklab.l, white.L / 4, accuracy: 1e-12)
    }
    func testSolidImageHasOneColor() throws {
        let input = image(Array(repeating: [64,128,192], count: 10))
        let output = try MedianCut().extract(input, mask: .all(width: 10, height: 1), params: .v1)
        XCTAssertEqual(output.result.colors.count, 1)
        XCTAssertEqual(output.result.colors[0].share, 1)
        XCTAssertEqual(output.result.colors[0].pixelCount, 10)
    }
    func testMaskedPixelsAreNotCounted() throws {
        let input = image([[255,0,0], [0,0,255]])
        let mask = EligibilityMask(width: 2, height: 1, eligible: [true,false])
        let output = try MedianCut().extract(input, mask: mask, params: params)
        XCTAssertEqual(output.result.eligiblePixelCount, 1)
        XCTAssertEqual(output.labelMap, [0,255])
    }
    func testNoEligiblePixelsThrows() throws {
        let input = image([[0,0,0]])
        let mask = EligibilityMask(width: 1, height: 1, eligible: [false])
        for method in [PaletteMethod.kmeansPP, .medianCut] {
            XCTAssertThrowsError(try makePaletteExtractor(method).extract(input, mask: mask, params: params)) {
                guard case PaletteExtractionError.noEligiblePixels = $0 else { return XCTFail("Wrong error") }
            }
        }
    }
    func testInvalidParametersThrow() throws {
        let input = image([[0,0,0]])
        var p = params; p.kInitial = 0
        for method in [PaletteMethod.kmeansPP, .medianCut] {
            XCTAssertThrowsError(try makePaletteExtractor(method).extract(input, mask: .all(width: 1, height: 1), params: p)) {
                guard case PaletteExtractionError.invalidParameters = $0 else { return XCTFail("Wrong error") }
            }
        }
    }
    func testMedianCutIgnoresSeedAndRepeatsExactly() throws {
        let input = image([[10,20,30], [210,50,80], [30,200,90], [255,255,255]])
        let mask = EligibilityMask.all(width: 4, height: 1)
        let a = try MedianCut().extract(input, mask: mask, params: params)
        var p = params; p.seed = 999
        let b = try MedianCut().extract(input, mask: mask, params: p)
        XCTAssertEqual(a.result, b.result)
        XCTAssertEqual(a.labelMap, b.labelMap)
    }
    func testSampleStrideCountsAllPixels() throws {
        let input = image([[255,0,0], [0,0,255], [255,0,0], [0,0,255]])
        var p = params; p.sampleStride = 2
        let output = try MedianCut().extract(input, mask: .all(width: 4, height: 1), params: p)
        XCTAssertEqual(output.result.eligiblePixelCount, 4)
        XCTAssertEqual(output.result.colors.reduce(0) { $0 + $1.pixelCount }, 4)
        XCTAssertEqual(output.labelMap.count, 4)
        XCTAssertFalse(output.labelMap.contains(255))
    }
}
