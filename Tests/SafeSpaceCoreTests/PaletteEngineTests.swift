import XCTest
@testable import SafeSpaceCore

final class PaletteEngineTests: XCTestCase {
    private func image(_ rgb: [[UInt8]]) -> SRGBImage {
        SRGBImage(width: rgb.count, height: 1, rgba: rgb.flatMap { $0 + [255] })
    }
    private func output(_ image: SRGBImage, params: PaletteParams = .v1) throws -> PaletteOutput {
        try KMeansPlusPlus().extract(image, mask: .all(width: image.width, height: image.height), params: params)
    }
    func testSolidRed() throws {
        let result = try output(image(Array(repeating: [255, 0, 0], count: 100)))
        XCTAssertEqual(result.result.colors.count, 1)
        XCTAssertEqual(result.result.colors[0].hex, "#FF0000")
        XCTAssertEqual(result.result.colors[0].share, 1)
        XCTAssertTrue(result.labelMap.allSatisfy { $0 == 0 })
    }
    func testExactShares() throws {
        let input = image(Array(repeating: [255, 0, 0], count: 75) + Array(repeating: [0, 0, 255], count: 25))
        let result = try output(input).result
        XCTAssertEqual(result.colors.map(\.share), [0.75, 0.25])
        XCTAssertEqual(result.colors.map(\.pixelCount), [75, 25])
    }
    func testTenRerunsHaveIdenticalPaletteJSON() throws {
        var rgb: [[UInt8]] = []
        for i in 0..<512 { rgb.append([UInt8(i % 256), UInt8((i * 37) % 256), UInt8((i * 19) % 256)]) }
        let input = image(rgb), expected = try AssessmentJSON.encoder().encode(output(input).result)
        for _ in 0..<10 {
            XCTAssertEqual(try AssessmentJSON.encoder().encode(output(input).result), expected)
        }
    }
    func testMaskDoesNotUseAlpha() throws {
        let input = SRGBImage(width: 2, height: 1, rgba: [255,0,0,0, 0,0,255,255])
        let all = try output(input).result
        XCTAssertEqual(all.eligiblePixelCount, 2)
        let excluded = try KMeansPlusPlus().extract(input,
            mask: .init(width: 2, height: 1, eligible: [false, true]), params: .v1)
        XCTAssertEqual(excluded.result.colors.first?.hex, "#0000FF")
        XCTAssertEqual(excluded.labelMap, [255, 0])
        XCTAssertTrue(excluded.result.maskApplied)
    }
    func testNoEligiblePixelsThrows() {
        let input = image([[255,0,0]])
        XCTAssertThrowsError(try KMeansPlusPlus().extract(input,
            mask: .init(width: 1, height: 1, eligible: [false]), params: .v1))
    }
    func testDroppingDoesNotRenormalize() throws {
        let input = image(Array(repeating: [255,0,0], count: 99) + [[0,0,255]])
        var params = PaletteParams.v1; params.minShare = 0.02
        let out = try output(input, params: params)
        XCTAssertEqual(out.result.colors[0].share, 0.99)
        XCTAssertEqual(out.result.droppedShare, 0.01)
        XCTAssertEqual(out.labelMap.last, 255)
    }
    func testAchromaticHueIsNull() throws {
        let c = try output(image([[128,128,128]])).result.colors[0]
        XCTAssertNil(c.oklch.h)
        let data = try AssessmentJSON.encoder().encode(c)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lch = try XCTUnwrap(root["oklch"] as? [String: Any])
        XCTAssertTrue(lch["h"] is NSNull)
    }
    func testPNGOrientationAndRoundTrip() throws {
        let input = SRGBImage(width: 2, height: 2,
            rgba: [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255])
        XCTAssertEqual(try SRGBImage(pngData: input.pngData()), input)
        let mask = EligibilityMask(width: 2, height: 2, eligible: [true,false,false,true])
        XCTAssertEqual(try EligibilityMask(pngData: mask.pngData()), mask)
    }
    func testPipelineRecordRoundTripAndNullKeys() async throws {
        let input = image(Array(repeating: [255,0,0], count: 16)).pngData()
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "test", os: "test")
        let output = try await AssessmentPipeline.run(imageData: input, source: .library,
            roomID: UUID().uuidString.lowercased(), producer: producer)
        XCTAssertEqual(output.record.overallState, .complete)
        XCTAssertEqual(output.record.steps.quality.status, .skipped)
        XCTAssertEqual(output.record.steps.anonymization.status, .skipped)
        let data = try AssessmentJSON.encode(output.record)
        XCTAssertEqual(try AssessmentJSON.decode(data), output.record)
        XCTAssertFalse(output.record.image.original.retained)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.people_not_masked" })
        XCTAssertFalse(output.record.findings.contains { Findings.containsBannedTerm($0.text) })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unknown_key"] = true
        XCTAssertThrowsError(try AssessmentJSON.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testMedianCutIsDeterministic() throws {
        let input = image([[255,0,0],[255,0,0],[0,0,255],[0,255,0]])
        let mask = EligibilityMask.all(width: 4, height: 1)
        let first = try MedianCut().extract(input, mask: mask, params: .v1)
        XCTAssertEqual(try MedianCut().extract(input, mask: mask, params: .v1).result, first.result)
    }
    func testCIELABUsesStoredSRGB8() throws {
        let color = try output(image([[30,90,170], [35,95,175]])).result.colors[0]
        let reference = ColorSpace.sRGBToCIELAB(r: Double(color.srgb8[0]) / 255,
            g: Double(color.srgb8[1]) / 255, b: Double(color.srgb8[2]) / 255)
        XCTAssertEqual(color.cielab.l, reference.L)
        XCTAssertEqual(color.cielab.a, reference.a)
        XCTAssertEqual(color.cielab.b, reference.b)
    }
    func testNonDefaultParamsRemainDeterministic() throws {
        let input = image([[1,2,3],[70,80,90],[240,230,220],[20,180,30],[200,40,50]])
        var params = PaletteParams.v1
        params.seed = 12345; params.kInitial = 3; params.mergeDeltaEOk = 0
        let expected = try output(input, params: params).result
        XCTAssertEqual(try output(input, params: params).result, expected)
    }

    // MARK: Task 7 "done when": merge, drop and rerun rules

    /// Smooth gradient with no natural clusters, so a change in seeding changes the palette.
    private func gradient(width: Int = 64, height: Int = 48) -> SRGBImage {
        var rgba: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { rgba += [UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)), 128, 255] }
        }
        return SRGBImage(width: width, height: height, rgba: rgba)
    }
    func testTenRerunsOfGradientAreBitIdenticalIncludingLabelMap() throws {
        let input = gradient(), first = try output(input)
        let expected = try AssessmentJSON.encoder().encode(first.result)
        for run in 2...10 {
            let next = try output(input)
            XCTAssertEqual(try AssessmentJSON.encoder().encode(next.result), expected, "run \(run)")
            XCTAssertEqual(next.labelMap, first.labelMap, "run \(run)")
        }
    }
    func testCloseColorsMergeIntoTheirMean() throws {
        // About 0.006 apart in OKLab, under the 0.04 merge threshold
        let input = image(Array(repeating: [200, 100, 100], count: 60) + Array(repeating: [203, 100, 100], count: 40))
        let result = try output(input).result
        XCTAssertEqual(result.colors.count, 1)
        XCTAssertEqual(result.colors[0].pixelCount, 100)
        let low = ColorSpace.sRGBToOKLab(r: 200 / 255, g: 100 / 255, b: 100 / 255)
        let high = ColorSpace.sRGBToOKLab(r: 203 / 255, g: 100 / 255, b: 100 / 255)
        XCTAssertEqual(result.colors[0].oklab.l, 0.6 * low.L + 0.4 * high.L, accuracy: 1e-12)
    }
    func testDistinctColorsAreKeptAndRanked() throws {
        let input = image(Array(repeating: [255, 0, 0], count: 40) + Array(repeating: [0, 128, 0], count: 30)
            + Array(repeating: [0, 0, 255], count: 20) + Array(repeating: [255, 255, 255], count: 10))
        let result = try output(input).result
        XCTAssertEqual(result.colors.map(\.hex), ["#FF0000", "#008000", "#0000FF", "#FFFFFF"])
        XCTAssertEqual(result.colors.map(\.id), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(result.colors.map(\.share), [0.4, 0.3, 0.2, 0.1])
        XCTAssertEqual(result.droppedShare, 0)
    }
    func testDefaultMinShareDropsColorsUnderOnePercent() throws {
        let input = image(Array(repeating: [255, 0, 0], count: 995) + Array(repeating: [0, 0, 255], count: 5))
        let out = try output(input)
        XCTAssertEqual(out.result.colors.map(\.hex), ["#FF0000"])
        XCTAssertEqual(out.result.droppedShare, 0.005, accuracy: 1e-12)
        XCTAssertEqual(Array(out.labelMap.suffix(5)), [255, 255, 255, 255, 255])
    }
    func testResultInvariantsOnGradient() throws {
        let input = gradient(), out = try output(input), result = out.result
        XCTAssertTrue((1...PaletteParams.v1.kInitial).contains(result.colors.count))
        XCTAssertEqual(result.colors.map(\.share), result.colors.map(\.share).sorted(by: >))
        XCTAssertEqual(result.colors.map(\.share).reduce(0, +) + result.droppedShare, 1, accuracy: 1e-9)
        for (index, color) in result.colors.enumerated() {
            XCTAssertEqual(color.rank, index + 1)
            XCTAssertEqual(color.id, "c\(index + 1)")
            XCTAssertEqual(color.hex, String(format: "#%02X%02X%02X", Int(color.srgb8[0]), Int(color.srgb8[1]), Int(color.srgb8[2])))
            XCTAssertEqual(color.oklch.h == nil, color.oklch.c < 0.002)
            XCTAssertEqual(out.labelMap.filter { $0 == UInt8(index) }.count, color.pixelCount)
        }
    }
    func testSampleStrideStillCountsEveryPixel() throws {
        let input = gradient()
        var params = PaletteParams.v1; params.sampleStride = 3
        let out = try output(input, params: params), result = out.result
        XCTAssertEqual(result.eligiblePixelCount, input.width * input.height)
        XCTAssertEqual(result.colors.map(\.share).reduce(0, +) + result.droppedShare, 1, accuracy: 1e-9)
        XCTAssertEqual(out.labelMap.filter { $0 == 255 }.count,
                       result.eligiblePixelCount - result.colors.map(\.pixelCount).reduce(0, +))
        XCTAssertEqual(try output(input, params: params).result, result)
    }
}
