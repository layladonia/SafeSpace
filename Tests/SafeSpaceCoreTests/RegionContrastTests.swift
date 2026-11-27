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

    func testContrastDifferenceBandsUseNonOverlappingRanges() {
        let cases: [(Double, ContrastDifferenceBand)] = [
            (0, .imperceptible), (1, .imperceptible),
            (1.01, .veryLow), (5, .veryLow),
            (5.01, .moderate), (15, .moderate),
            (15.01, .clear), (30, .clear),
            (30.01, .high), (60, .high),
            (60.01, .veryHigh), (100, .veryHigh),
            (100.01, .veryHigh)
        ]
        for (deltaE, expected) in cases {
            XCTAssertEqual(ContrastDifferenceBand(deltaE: deltaE), expected, "ΔE00 \(deltaE)")
        }
        XCTAssertNil(ContrastDifferenceBand(deltaE: -0.01))
        XCTAssertNil(ContrastDifferenceBand(deltaE: .nan))
        XCTAssertNil(ContrastDifferenceBand(deltaE: .infinity))
    }

    func testMatchesDirectFormulaOnSolidRegions() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let result = try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf, minEligiblePixels: 1)

        let expected = ColorDifference.ciede2000(
            ColorSpace.sRGBToCIELAB(r: 200 / 255.0, g: 20 / 255.0, b: 20 / 255.0),
            ColorSpace.sRGBToCIELAB(r: 20 / 255.0, g: 20 / 255.0, b: 200 / 255.0)
        )
        XCTAssertEqual(result.deltaE, expected, accuracy: 1e-9)
        XCTAssertEqual(result.region1.pixelCount, 4)
        XCTAssertEqual(result.region2.pixelCount, 4)
        XCTAssertNil(result.label)
    }

    func testIdenticalRegionsHaveZeroDifference() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let result = try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: leftHalf, minEligiblePixels: 1)
        XCTAssertEqual(result.deltaE, 0.0)
    }

    func testSwappingRegionsGivesSameDelta() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let forward = try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf, minEligiblePixels: 1)
        let reverse = try RegionContrast.measure(image, mask: mask, region1: rightHalf, region2: leftHalf, minEligiblePixels: 1)
        XCTAssertEqual(forward.deltaE, reverse.deltaE, accuracy: 1e-12)
    }

    func testNoEligiblePixelsThrows() throws {
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height).excluding([leftHalf])
        XCTAssertThrowsError(try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf, minEligiblePixels: 1)) { error in
            guard case RegionContrastError.regionTooSmall(region: 1) = error else {
                return XCTFail("Expected regionTooSmall(region: 1), got \(error)")
            }
        }
    }

    func testFewerThanMinEligiblePixelsThrows() throws {
        // 4x2 region has 4 eligible pixels on the left half; the default minimum (100) rejects it.
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        XCTAssertThrowsError(try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf)) { error in
            guard case RegionContrastError.regionTooSmall(region: 1) = error else {
                return XCTFail("Expected regionTooSmall(region: 1), got \(error)")
            }
        }
    }

    /// A larger synthetic image so each half clears the default 100-eligible-pixel minimum.
    private func largeSplitImage(a: [UInt8], b: [UInt8]) -> SRGBImage {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(40 * 20 * 4)
        for _ in 0..<20 {
            for _ in 0..<20 { rgba.append(contentsOf: a + [255]) }
            for _ in 0..<20 { rgba.append(contentsOf: b + [255]) }
        }
        return SRGBImage(width: 40, height: 20, rgba: rgba)
    }

    func testPipelineCompletesContrastWhenRegionsRequested() async throws {
        let image = largeSplitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        var options = PipelineOptions()
        options.contrastRegion1 = leftHalf
        options.contrastRegion2 = rightHalf

        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: options
        )

        XCTAssertEqual(output.record.steps.contrast.status, .completed)
        let measurements = try XCTUnwrap(output.record.steps.contrast.result?.measurements)
        XCTAssertEqual(measurements.count, 1)
        XCTAssertGreaterThan(measurements[0].deltaE, 0)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.contrast_not_judgment" })

        // Must round-trip through the real validator and full JSON encode/decode.
        let data = try AssessmentJSON.encode(output.record)
        _ = try AssessmentJSON.decode(data)
    }

    func testPipelineSkipsContrastWhenNoRegionsRequested() async throws {
        let image = largeSplitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: PipelineOptions()
        )
        XCTAssertEqual(output.record.steps.contrast.status, .skipped)
        XCTAssertEqual(output.record.steps.contrast.reason, .notRequested)
        XCTAssertFalse(output.record.findings.contains { $0.templateId == "limitation.contrast_not_judgment" })
    }

    func testPipelineFailsContrastWhenARegionIsTooSmall() async throws {
        // The 4x2 synthetic image's halves have only 4 eligible pixels each, under the default
        // 100-pixel minimum, so the pipeline should record a failed contrast step, not a result
        // built from a statistically meaningless average.
        let image = splitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        var options = PipelineOptions()
        options.contrastRegion1 = leftHalf
        options.contrastRegion2 = rightHalf

        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: options
        )

        XCTAssertEqual(output.record.steps.contrast.status, .failed)
        XCTAssertEqual(output.record.steps.contrast.reason, .contrastCalculationFailed)
        XCTAssertNil(output.record.steps.contrast.result)
    }

    func testAddContrastAppendsToAnExistingCompletedMeasurement() async throws {
        let image = largeSplitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        var options = PipelineOptions()
        options.contrastRegion1 = leftHalf
        options.contrastRegion2 = rightHalf
        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: options
        )
        XCTAssertEqual(output.record.steps.contrast.status, .completed)
        XCTAssertEqual(output.record.steps.contrast.result?.measurements.count, 1)

        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let updated = try AssessmentPipeline.addContrast(
            to: output.record, image: image, mask: mask, region1: rightHalf, region2: leftHalf, label: "wall vs floor"
        )

        XCTAssertEqual(updated.steps.contrast.status, .completed)
        let measurements = try XCTUnwrap(updated.steps.contrast.result?.measurements)
        XCTAssertEqual(measurements.count, 2)
        XCTAssertEqual(measurements[1].label, "wall vs floor")
        XCTAssertNotEqual(measurements[0].measurementId, measurements[1].measurementId)
        XCTAssertTrue(updated.updatedAt >= output.record.updatedAt)
        let contrastLimitations = updated.findings.filter { $0.templateId == "limitation.contrast_not_judgment" }
        XCTAssertEqual(contrastLimitations.count, 1)
        XCTAssertEqual(contrastLimitations.first?.sources, [
            "/steps/contrast/result/measurements/0/delta_e", "/steps/contrast/result/measurements/1/delta_e"
        ])

        // Must round-trip through the real validator and full JSON encode/decode.
        let data = try AssessmentJSON.encode(updated)
        _ = try AssessmentJSON.decode(data)
    }

    func testAddContrastStartsTheArrayWhenContrastWasSkipped() async throws {
        let image = largeSplitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: PipelineOptions()
        )
        XCTAssertEqual(output.record.steps.contrast.status, .skipped)

        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let updated = try AssessmentPipeline.addContrast(to: output.record, image: image, mask: mask, region1: leftHalf, region2: rightHalf)
        XCTAssertEqual(updated.steps.contrast.status, .completed)
        XCTAssertEqual(updated.steps.contrast.result?.measurements.count, 1)
    }

    func testAddContrastLeavesTheRecordUntouchedWhenARegionIsTooSmall() async throws {
        let image = largeSplitImage(a: [200, 20, 20], b: [20, 20, 200])
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        let output = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: PipelineOptions()
        )
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let sliver = NormalizedRect(x: 0, y: 0, width: 0.01, height: 0.01)
        XCTAssertThrowsError(try AssessmentPipeline.addContrast(to: output.record, image: image, mask: mask, region1: sliver, region2: rightHalf))
    }

    /// 40x20 image whose left half is 3/4 red and 1/4 white, so its mean and median CIELAB differ;
    /// the right half is solid blue.
    private func mixedLeftImage() -> SRGBImage {
        var rgba: [UInt8] = []
        for y in 0..<20 {
            for _ in 0..<20 { rgba.append(contentsOf: y % 4 == 0 ? [255, 255, 255, 255] : [200, 20, 20, 255]) }
            for _ in 0..<20 { rgba.append(contentsOf: [20, 20, 200, 255]) }
        }
        return SRGBImage(width: 40, height: 20, rgba: rgba)
    }

    /// A record compared before the median switch, as it is saved on disk: same shape as today,
    /// with the mean method's name.
    private func legacyRecord(image: SRGBImage) async throws -> AssessmentRecord {
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "unit-test", os: "unit-test")
        var options = PipelineOptions()
        options.contrastRegion1 = leftHalf
        options.contrastRegion2 = rightHalf
        var record = try await AssessmentPipeline.run(
            imageData: image.pngData(), source: .library, roomID: UUID().uuidString.lowercased(),
            producer: producer, options: options
        ).record
        record.steps.contrast.method?.name = RegionContrast.legacyMethodName
        return record
    }

    func testLegacyMeanRecordStillDecodes() async throws {
        let record = try await legacyRecord(image: mixedLeftImage())
        let decoded = try AssessmentJSON.decode(try AssessmentJSON.encoder().encode(record))
        XCTAssertEqual(decoded.steps.contrast.method?.name, RegionContrast.legacyMethodName)
        XCTAssertEqual(decoded.steps.contrast.result?.measurements.count, 1)
    }

    func testAddContrastKeepsTheLegacyMeanMethod() async throws {
        let image = mixedLeftImage()
        let mask = EligibilityMask.all(width: image.width, height: image.height)
        let record = try await legacyRecord(image: image)

        let updated = try AssessmentPipeline.addContrast(to: record, image: image, mask: mask, region1: leftHalf, region2: rightHalf)

        XCTAssertEqual(updated.steps.contrast.method?.name, RegionContrast.legacyMethodName)
        let added = try XCTUnwrap(updated.steps.contrast.result?.measurements.last)
        let mean = try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf, useLegacyMean: true)
        let median = try RegionContrast.measure(image, mask: mask, region1: leftHalf, region2: rightHalf)
        XCTAssertNotEqual(mean.deltaE, median.deltaE, accuracy: 0.5, "Fixture must tell the two methods apart")
        XCTAssertEqual(added.deltaE, mean.deltaE, accuracy: 1e-12)
        _ = try AssessmentJSON.decode(try AssessmentJSON.encode(updated))
    }

    func testUnknownContrastMethodIsStillRejected() async throws {
        var record = try await legacyRecord(image: mixedLeftImage())
        record.steps.contrast.method?.name = "region_mode_ciede2000"
        XCTAssertThrowsError(try AssessmentValidator.validate(record))
    }

    /// Fixture photos: a plain vertical split, solid color on each half (TestImages/).
    private static let testImagesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("TestImages")

    func testContrastReferenceImages() throws {
        let cases: [(file: String, expectedDeltaE: Double)] = [
            ("contrasttest1.jpg", 1.65),
            ("contrasttest2.jpg", 4.19),
            ("contrasttest3.jpg", 5.73),
            ("contrasttest4.jpg", 8.45),
            ("contrasttest5.jpg", 24.11),
            ("contrasttest6.jpg", 57.02),
        ]
        // Each fixture is a real exported JPEG of an intended hex swatch pair, not the swatch
        // itself: region1's measured average matches its intended hex almost to machine
        // precision in every file, but region2 drifts further from its intended hex as the
        // two swatches get more different (up to ~0.9 ΔE00 of drift on the most extreme pair,
        // contrasttest6) — ordinary JPEG-compression/photographic noise, not a region-selection
        // bug. 0.5 comfortably covers the worst observed drift while still catching a real
        // regression in the CIELAB/CIEDE2000 pipeline.
        for (file, expected) in cases {
            let copy = try ImageLoader.load(url: Self.testImagesDir.appendingPathComponent(file))
            let mask = EligibilityMask.all(width: copy.image.width, height: copy.image.height)
            let result = try RegionContrast.measure(copy.image, mask: mask, region1: leftHalf, region2: rightHalf)
            XCTAssertEqual(result.deltaE, expected, accuracy: 0.5, file)
        }
    }

    func testFindingWordingHasNoBannedTerms() {
        let text = "This number measures the color difference between the two selected areas in this photo. "
            + "It does not measure whether a person can see that difference, and it is not a judgment about the room."
        XCTAssertFalse(Findings.containsBannedTerm(text))
    }
}
