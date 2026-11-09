import Foundation
import XCTest
@testable import SafeSpaceCore

final class RegionContrastTests: XCTestCase {
    /// 4x2 image: left two columns solid color A, right two columns solid color B.
    private func splitImage(a: [UInt8], b: [UInt8]) -> SRGBImage {
        var rgba: [UInt8] = []
        for _ in 0..<2 {
            rgba.append(contentsOf: a + [255]); rgba.append(contentsOf: a + [255])
            rgba.append(contentsOf: b + [255]); rgba.append(contentsOf: b + [255])
        }
        return SRGBImage(width: 4, height: 2, rgba: rgba)
    }

    private let leftHalf = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
    private let rightHalf = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

    func testMatchesDirectFormulaOnSolidRegions() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let result = try RegionContrast.compare(image, mask: mask, region1: leftHalf, region2: rightHalf)

        let expected = ColorDifference.ciede2000(
            ColorSpace.sRGBToCIELAB(r: 200 / 255.0, g: 20 / 255.0, b: 20 / 255.0),
            ColorSpace.sRGBToCIELAB(r: 20 / 255.0, g: 20 / 255.0, b: 200 / 255.0)
        )
        XCTAssertEqual(result.deltaE, expected, accuracy: 1e-9)
        XCTAssertEqual(result.colorSpace, "cielab")
        XCTAssertEqual(result.formula, "ciede2000")
        XCTAssertEqual(result.region1.pixelCount, 4)
        XCTAssertEqual(result.region2.pixelCount, 4)
    }

    func testIdenticalRegionsHaveZeroDifference() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let result = try RegionContrast.compare(image, mask: mask, region1: leftHalf, region2: leftHalf)
        XCTAssertEqual(result.deltaE, 0.0)
    }

    func testSwappingRegionsGivesSameDelta() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let forward = try RegionContrast.compare(image, mask: mask, region1: leftHalf, region2: rightHalf)
        let reverse = try RegionContrast.compare(image, mask: mask, region1: rightHalf, region2: leftHalf)
        XCTAssertEqual(forward.deltaE, reverse.deltaE, accuracy: 1e-12)
    }

    func testNoEligiblePixelsThrows() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height).excluding([leftHalf])
        XCTAssertThrowsError(try RegionContrast.compare(image, mask: mask, region1: leftHalf, region2: rightHalf)) { error in
            guard case RegionContrastError.noEligiblePixels(region: 1) = error else {
                return XCTFail("Expected noEligiblePixels(region: 1), got \(error)")
            }
        }
    }

    func testPipelineCompletesContrastWhenRegionsRequested() async throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        var options = PipelineOptions()
        options.contrastRegion1 = leftHalf
        options.contrastRegion2 = rightHalf

        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: options
        )

        XCTAssertEqual(output.record.steps.contrast.status, .completed)
        let result = try XCTUnwrap(output.record.steps.contrast.result)
        XCTAssertGreaterThan(result.deltaE, 0)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.contrast_not_judgment" })

        // Must round-trip through the real validator and full JSON encode/decode.
        let data = try AssessmentJSON.encode(output.record)
        _ = try AssessmentJSON.decode(data)
    }

    func testPipelineSkipsContrastWhenNoRegionsRequested() async throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: PipelineOptions()
        )
        XCTAssertEqual(output.record.steps.contrast.status, .skipped)
        XCTAssertEqual(output.record.steps.contrast.reason, .notRequested)
        XCTAssertFalse(output.record.findings.contains { $0.templateId == "limitation.contrast_not_judgment" })
    }

    func testFindingWordingHasNoBannedTerms() {
        let text = "This number measures the color difference between the two selected areas in this photo. "
            + "It does not measure whether a person can see that difference, and it is not a judgment about the room."
        XCTAssertFalse(Findings.containsBannedTerm(text))
    }
}
