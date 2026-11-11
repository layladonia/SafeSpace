import XCTest
@testable import SafeSpaceCore

final class AnonymizationTests: XCTestCase {
    private var image: SRGBImage {
        let pixels: [[UInt8]] = (0..<64).map { i in i % 8 < 4 ? [255,0,0] : [0,0,255] }
        return .init(width: 8, height: 8, rgba: pixels.flatMap { $0 + [255] })
    }
    private func region(_ x: Double = 0, _ y: Double = 0, _ w: Double = 0.5,
                        _ h: Double = 1) -> DetectedRegion {
        .init(kind: "person", rect: .init(x: x, y: y, width: w, height: h), confidence: 1)
    }
    private func run(_ anonymizer: any Anonymizer, room: String = UUID().uuidString.lowercased()) async throws -> PipelineOutput {
        var options = PipelineOptions(); options.anonymizer = anonymizer
        options.paletteParams.mergeDeltaEOk = 0
        options.paletteParams.minShare = 0
        return try await AssessmentPipeline.run(imageData: image.pngData(), source: .library, roomID: room,
            producer: .init(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version,
                            device: "test", os: "test"), options: options)
    }
    func testQualityAndAnonymizationCompleteTogether() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region()]))
        XCTAssertEqual(output.record.steps.quality.status, .completed)
        XCTAssertEqual(output.record.steps.anonymization.status, .completed)
        XCTAssertEqual(try AssessmentJSON.decode(AssessmentJSON.encode(output.record)), output.record)
    }
    func testNonDefaultVisionParametersAreRecorded() async throws {
        var params = AnonymizationParams.v1
        params.blurRadiusPx = 7
        params.boxPadding = 0.2
        let output = try await run(FixtureAnonymizer(regions: [region()], params: params))
        let method = try XCTUnwrap(output.record.steps.anonymization.method)
        XCTAssertEqual(try method.params.decoded(as: AnonymizationParams.self), params)
    }
    func testOtherRectangleMethodRoundTrips() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region()], methodName: "fixture_rectangles"))
        XCTAssertEqual(output.record.steps.anonymization.status, .completed)
        XCTAssertEqual(output.record.steps.anonymization.method?.name, "fixture_rectangles")
        XCTAssertEqual(try AssessmentJSON.decode(AssessmentJSON.encode(output.record)), output.record)
    }
    func testDetectionFailedIsNotUnavailable() async throws {
        let output = try await run(FixtureAnonymizer(regions: [], failure: .detectionFailed))
        XCTAssertEqual(output.record.steps.anonymization.reason, .anonymizationFailed)
        XCTAssertNil(output.storedImage)
    }
    func testVisionIsDefault() {
        XCTAssertTrue(PipelineOptions().anonymizer is VisionAnonymizer)
        XCTAssertEqual(AnonymizationParams.v1.boxPadding, 0.10)
        XCTAssertEqual(AnonymizationParams.v1.blurRadiusPx, 24)
    }
    func testBottomLeftConversionAndPadding() throws {
        let rect = try PrivacyMasking.topLeftPaddedRect(x: 0.2, y: 0.6, width: 0.2, height: 0.2, padding: 0.1)
        XCTAssertEqual(rect.x, 0.18, accuracy: 1e-12)
        XCTAssertEqual(rect.y, 0.18, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 0.24, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 0.24, accuracy: 1e-12)
    }
    func testPaddingClipsAtImageEdges() throws {
        let r = try PrivacyMasking.topLeftPaddedRect(x: 0, y: 0, width: 1, height: 1, padding: 0.1)
        XCTAssertEqual(r, .init(x: 0, y: 0, width: 1, height: 1))
    }
    func testInvalidCoordinatesRejected() {
        XCTAssertThrowsError(try PrivacyMasking.topLeftPaddedRect(x: .nan, y: 0, width: 1, height: 1, padding: 0.1))
    }
    func testOverlapCountedOnce() throws {
        let output = try PrivacyMasking.apply(image, regions: [region(), region()], radius: 2, mayBeIncomplete: true)
        XCTAssertEqual(output.result.maskedShare, 0.5)
        XCTAssertEqual(output.mask.eligibleCount, 32)
    }
    func testBlurChangesMaskedPixelsButNotEligiblePixels() throws {
        let output = try PrivacyMasking.apply(image, regions: [region()], radius: 2, mayBeIncomplete: true)
        XCTAssertNotEqual(output.anonymizedImage, image)
        for i in output.mask.eligible.indices where output.mask.eligible[i] {
            XCTAssertEqual(Array(output.anonymizedImage.rgba[i*4..<i*4+4]), Array(image.rgba[i*4..<i*4+4]))
        }
        try PrivacyMasking.validate(output, against: image)
    }
    func testEmptyDetectionIsCompletedNotFailure() async throws {
        let output = try await run(FixtureAnonymizer(regions: []))
        XCTAssertEqual(output.record.steps.anonymization.status, .completed)
        XCTAssertEqual(output.record.steps.anonymization.result?.maskedShare, 0)
        XCTAssertEqual(output.storedImage, image)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.anonymization_incomplete" })
    }
    func testMaskedRedPixelsDoNotAffectBluePalette() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region()]))
        let palette = try XCTUnwrap(output.record.steps.palette.result)
        XCTAssertTrue(palette.maskApplied)
        XCTAssertEqual(palette.eligiblePixelCount, 32)
        XCTAssertEqual(palette.colors.count, 1)
        XCTAssertEqual(palette.colors.first?.hex, "#0000FF")
        for i in output.mask.eligible.indices where !output.mask.eligible[i] {
            XCTAssertEqual(output.labelMap?[i], 255)
        }
    }
    func testAllPixelsMaskedFailsPaletteOnly() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region(0,0,1,1)]))
        XCTAssertEqual(output.record.steps.anonymization.status, .completed)
        XCTAssertEqual(output.record.steps.palette.reason, .noEligiblePixels)
        XCTAssertNotNil(output.storedImage)
    }
    func testDetectionUnavailableRunsUnmaskedPaletteButNeverStoresPhoto() async throws {
        let output = try await run(FixtureAnonymizer(regions: [], failure: .detectionUnavailable))
        XCTAssertEqual(output.record.steps.anonymization.reason, .detectionUnavailable)
        XCTAssertEqual(output.record.steps.palette.status, .completed)
        XCTAssertEqual(output.record.steps.palette.result?.maskApplied, false)
        XCTAssertNil(output.storedImage)
        XCTAssertEqual(output.record.overallState, .partial)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.people_not_masked" })
    }
    func testInvalidDetectorOutputIsFailureNotCompletion() async throws {
        let output = try await run(FixtureAnonymizer(regions: [], invalidOutput: true))
        XCTAssertEqual(output.record.steps.anonymization.reason, .anonymizationFailed)
        XCTAssertNil(output.storedImage)
    }
    func testCancellationEscapesPipeline() async {
        do { _ = try await run(FixtureAnonymizer(regions: [], cancel: true)); XCTFail("Cancellation swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCompletedJSONRoundTripAndUnknownPrivacyKeyRejected() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region()]))
        let data = try AssessmentJSON.encode(output.record)
        XCTAssertEqual(try AssessmentJSON.decode(data), output.record)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var steps = root["steps"] as! [String: Any]
        var step = steps["anonymization"] as! [String: Any]
        var result = step["result"] as! [String: Any]; result["unknown"] = true
        step["result"] = result; steps["anonymization"] = step; root["steps"] = steps
        XCTAssertThrowsError(try AssessmentJSON.decode(JSONSerialization.data(withJSONObject: root)))
    }
    func testWrongMaskedShareRejected() async throws {
        var record = try await run(FixtureAnonymizer(regions: [region()])).record
        record.steps.anonymization.result?.maskedShare = 0
        XCTAssertThrowsError(try AssessmentValidator.validate(record))
    }
    func testStorageReopensProcessedArtifactsAndNeverWritesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores: [any AssessmentStore] = [FileAssessmentStore(root: root), InMemoryAssessmentStore()]
        for store in stores {
            let room = try await store.createRoom(name: "Privacy test")
            let output = try await run(FixtureAnonymizer(regions: [region()]), room: room.id)
            let record = try await store.save(output)
            let loaded = try await store.load(assessmentID: record.assessmentId)
            XCTAssertEqual(loaded.record, record)
            XCTAssertEqual(loaded.image, output.storedImage)
            XCTAssertNotEqual(loaded.image, image)
            XCTAssertEqual(loaded.mask, output.mask)
            XCTAssertEqual(loaded.labelMap, output.labelMap)
            if store is FileAssessmentStore {
                let dir = root.appendingPathComponent("rooms/\(room.id)/assessments/\(record.assessmentId)")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                               ["assessment.json", "image.png", "labels.png", "mask.png"])
                let fresh = FileAssessmentStore(root: root)
                let reopened = try await fresh.load(assessmentID: record.assessmentId)
                XCTAssertEqual(reopened.record, record)
                XCTAssertEqual(reopened.image, loaded.image)
            }
        }
    }
    func testStoreRejectsPhotoAfterPrivacyFailure() async throws {
        let store = InMemoryAssessmentStore()
        let room = await store.createRoom(name: "Failure")
        let output = try await run(FixtureAnonymizer(regions: [], failure: .detectionUnavailable), room: room.id)
        let bad = PipelineOutput(record: output.record, storedImage: image, mask: output.mask,
                                 labelMap: output.labelMap, totalDurationMs: 0)
        do { _ = try await store.save(bad); XCTFail("Unmasked photo persisted") } catch { XCTAssertTrue(error is SafeSpaceError) }
        let saved = try await store.save(output)
        let loaded = try await store.load(assessmentID: saved.assessmentId)
        XCTAssertNil(loaded.image)
    }
    func testAppleVisionSmokeWhenEnabled() async throws {
        #if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
        guard ProcessInfo.processInfo.environment["RUN_VISION_SMOKE"] == "1" else {
            throw XCTSkip("Set RUN_VISION_SMOKE=1 on macOS to exercise live Vision, not just fixtures")
        }
        let output = try await run(VisionAnonymizer())
        XCTAssertEqual(output.record.steps.anonymization.status, .completed,
                       "Live Vision failed: \(String(describing: output.record.steps.anonymization.reason))")
        XCTAssertNotNil(output.storedImage)
        try AssessmentValidator.validate(output.record)
        #else
        throw XCTSkip("Vision is unavailable on this platform")
        #endif
    }
    func testNoOpRemainsAnExplicitSkippedOptOut() async throws {
        let output = try await run(NoOpAnonymizer())
        XCTAssertEqual(output.record.steps.anonymization.status, .skipped)
        XCTAssertNotNil(output.storedImage)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.people_not_masked" })
    }
}
private struct FixtureAnonymizer: Anonymizer {
    let regions: [DetectedRegion]
    var failure: AnonymizationError? = nil
    var cancel = false
    var invalidOutput = false
    var params: AnonymizationParams = .v1
    var methodName: String = "vision_faces_people"
    var methodVersion: Int { 1 }
    func encodedParameters() throws -> ContractJSON {
        try ContractJSON.encoding(params)
    }
    func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput {
        if cancel { throw CancellationError() }
        if let failure { throw failure }
        let output = try PrivacyMasking.apply(copy.image, regions: regions, radius: params.blurRadiusPx, mayBeIncomplete: true)
        if invalidOutput {
            return .init(result: .init(regions: [], maskedShare: 0.5, mayBeIncomplete: true),
                         mask: output.mask, anonymizedImage: output.anonymizedImage)
        }
        return output
    }
}
