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

}
