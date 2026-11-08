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
            try PaletteRunner.validate(output, image: input, mask: mask)
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
    }
    func testMaskedPixelsAreNotCounted() throws {
        let input = image([[255,0,0], [0,0,255]])
        let mask = EligibilityMask(width: 2, height: 1, eligible: [true,false])
        let output = try MedianCut().extract(input, mask: mask, params: params)
        XCTAssertEqual(output.result.eligiblePixelCount, 1)
        XCTAssertEqual(output.labelMap, [0,255])
        try PaletteRunner.validate(output, image: input, mask: mask)
    }
    func testNoEligiblePixelsThrows() throws {
        let input = image([[0,0,0]])
        let mask = EligibilityMask(width: 1, height: 1, eligible: [false])
        XCTAssertThrowsError(try PaletteRunner.extract(input, mask: mask)) {
            guard case PaletteExtractionError.noEligiblePixels = $0 else { return XCTFail("Wrong error") }
        }
    }
    func testInvalidParametersDoNotFallback() throws {
        let input = image([[0,0,0]])
        var p = params; p.kInitial = 0
        XCTAssertThrowsError(try PaletteRunner.extract(input, mask: .all(width: 1, height: 1), params: p)) {
            guard case PaletteExtractionError.invalidParameters = $0 else { return XCTFail("Wrong error") }
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
    func testRecoverableFailureFallsBackAndRecordsMethod() throws {
        let input = image([[255,0,0], [0,0,255]])
        let execution = try PaletteRunner.execute(input, mask: .all(width: 2, height: 1), params: params,
            method: .kmeansPP, fallback: .medianCutOnFailure, factory: { method in
                if method == .kmeansPP { return FailingExtractor(failure: .noRetainedColors) }
                return MedianCut()
            })
        XCTAssertEqual(execution.requestedMethod, .kmeansPP)
        XCTAssertEqual(execution.usedMethod, .medianCut)
        XCTAssertEqual(execution.fallbackReason, "no_retained_colors")
    }
    func testDisabledFallbackPropagatesFailure() throws {
        let input = image([[0,0,0]])
        XCTAssertThrowsError(try PaletteRunner.execute(input, mask: .all(width: 1, height: 1), params: params,
            method: .kmeansPP, fallback: .disabled, factory: { _ in
                FailingExtractor(failure: .noRetainedColors)
            }))
    }
    func testCancellationIsNotFallback() throws {
        let input = image([[0,0,0]])
        XCTAssertThrowsError(try PaletteRunner.execute(input, mask: .all(width: 1, height: 1), params: params,
            method: .kmeansPP, fallback: .medianCutOnFailure, factory: { _ in CancelledExtractor() })) {
                XCTAssertTrue($0 is CancellationError)
            }
    }
    func testInvalidOutputFallsBack() throws {
        let input = image([[255,0,0], [0,0,255]])
        let execution = try PaletteRunner.execute(input, mask: .all(width: 2, height: 1), params: params,
            method: .kmeansPP, fallback: .medianCutOnFailure, factory: { method in
                if method == .kmeansPP { return InvalidOutputExtractor() }
                return MedianCut()
            })
        XCTAssertEqual(execution.usedMethod, .medianCut)
        XCTAssertEqual(execution.fallbackReason, "invalid_output")
    }
    func testUnexpectedFailureDoesNotFallback() throws {
        let input = image([[0,0,0]])
        XCTAssertThrowsError(try PaletteRunner.execute(input, mask: .all(width: 1, height: 1), params: params,
            method: .kmeansPP, fallback: .medianCutOnFailure, factory: { _ in UnexpectedFailureExtractor() })) {
                XCTAssertTrue($0 is UnexpectedFailureExtractor.Failure)
            }
    }
    func testFailedSecondaryDoesNotRecurse() throws {
        let input = image([[0,0,0]])
        var calls = 0
        XCTAssertThrowsError(try PaletteRunner.execute(input, mask: .all(width: 1, height: 1), params: params,
            method: .kmeansPP, fallback: .medianCutOnFailure, factory: { _ in
                calls += 1
                return FailingExtractor(failure: .noRetainedColors)
            }))
        XCTAssertEqual(calls, 2)
    }
    func testSampleStrideCountsAllPixels() throws {
        let input = image([[255,0,0], [0,0,255], [255,0,0], [0,0,255]])
        var p = params; p.sampleStride = 2
        let mask = EligibilityMask.all(width: 4, height: 1)
        let output = try MedianCut().extract(input, mask: mask, params: p)
        XCTAssertEqual(output.result.colors.reduce(0) { $0 + $1.pixelCount }, 4)
        try PaletteRunner.validate(output, image: input, mask: mask)
    }
}
private struct FailingExtractor: PaletteExtractor {
    let failure: PaletteExtractionError
    var method: PaletteMethod { .kmeansPP }
    var methodVersion: Int { 1 }
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput {
        throw failure
    }
}
private struct CancelledExtractor: PaletteExtractor {
    var method: PaletteMethod { .kmeansPP }
    var methodVersion: Int { 1 }
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput {
        throw CancellationError()
    }
}

private struct InvalidOutputExtractor: PaletteExtractor {
    var method: PaletteMethod { .kmeansPP }
    var methodVersion: Int { 1 }
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput {
        let valid = try MedianCut().extract(image, mask: mask, params: params)
        return PaletteOutput(result: valid.result, labelMap: [])
    }
}
private struct UnexpectedFailureExtractor: PaletteExtractor {
    enum Failure: Error { case unexpected }
    var method: PaletteMethod { .kmeansPP }
    var methodVersion: Int { 1 }
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput {
        throw Failure.unexpected
    }
}
