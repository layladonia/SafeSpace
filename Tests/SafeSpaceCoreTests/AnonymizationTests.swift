import XCTest
@testable import SafeSpaceCore
#if canImport(Vision)
import Vision
#endif

final class AnonymizationTests: XCTestCase {
    private var image: SRGBImage {
        let pixels: [[UInt8]] = (0..<64).map { i in i % 8 < 4 ? [255,0,0] : [0,0,255] }
        return .init(width: 8, height: 8, rgba: pixels.flatMap { $0 + [255] })
    }
    private func region(_ x: Double = 0, _ y: Double = 0, _ w: Double = 0.5,
                        _ h: Double = 1) -> DetectedRegion {
        .init(kind: "person", rect: .init(x: x, y: y, width: w, height: h), confidence: 1)
    }
    private func run(_ anonymizer: any Anonymizer, room: String = UUID().uuidString.lowercased(),
                     input: SRGBImage? = nil, runAnonymization: Bool = true) async throws -> PipelineOutput {
        var options = PipelineOptions(); options.anonymizer = anonymizer
        options.runAnonymization = runAnonymization
        options.paletteParams.mergeDeltaEOk = 0
        options.paletteParams.minShare = 0
        return try await AssessmentPipeline.run(imageData: (input ?? image).pngData(), source: .library, roomID: room,
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
    func testUnknownAnonymizationMethodIsRejected() async {
        // Only methods this build knows are accepted (contract §4.6), like palette and quality.
        do {
            _ = try await run(FixtureAnonymizer(regions: [region()], methodName: "fixture_rectangles"))
            XCTFail("Unknown anonymization method accepted")
        } catch { XCTAssertTrue(error is SafeSpaceError, "\(error)") }
    }
    private func validationErrors(_ record: AssessmentRecord) -> [String] {
        do { try AssessmentValidator.validate(record); return [] }
        catch SafeSpaceError.validation(let messages) { return messages }
        catch { return ["\(error)"] }
    }
    func testCompletedStepRelabelledWithOtherMethodIsRejected() async throws {
        var record = try await run(FixtureAnonymizer(regions: [])).record
        XCTAssertEqual(validationErrors(record), [])
        for name in ["not_implemented", "foo"] {
            record.steps.anonymization.method?.name = name
            XCTAssertTrue(validationErrors(record).contains("Unknown anonymization method or version"), name)
        }
    }
    func testAnonymizationVersionRange() async throws {
        var record = try await run(FixtureAnonymizer(regions: [region()])).record
        for version in [0, VisionAnonymizer.methodVersion + 1] {
            record.steps.anonymization.method?.version = version
            XCTAssertTrue(validationErrors(record).contains("Unknown anonymization method or version"), "v\(version)")
        }
    }
    func testFailedStepMethodIsChecked() async throws {
        let base = try await run(FixtureAnonymizer(regions: [], failure: .detectionFailed)).record
        XCTAssertEqual(validationErrors(base), [])
        var renamed = base; renamed.steps.anonymization.method?.name = "foo"
        XCTAssertTrue(validationErrors(renamed).contains("Unknown anonymization method or version"))
        var unreadable = base; unreadable.steps.anonymization.method?.params = .object([:])
        XCTAssertTrue(validationErrors(unreadable).contains { $0.hasPrefix("Unreadable Vision anonymization parameters") })
    }
    func testOutOfRangeParamsStillRecordFailedStep() async throws {
        // Encodable but invalid params take the failed path (palette runs unmasked, no photo kept).
        var params = AnonymizationParams.v1; params.blurRadiusPx = 0
        let output = try await run(VisionAnonymizer(params: params))
        XCTAssertEqual(output.record.steps.anonymization.status, .failed)
        XCTAssertEqual(output.record.steps.anonymization.reason, .anonymizationFailed)
        XCTAssertNil(output.storedImage)
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
    func testRunAnonymizationFalseSkipsAsDisabledByUser() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region()]), runAnonymization: false)
        XCTAssertEqual(output.record.steps.anonymization.status, .skipped)
        XCTAssertEqual(output.record.steps.anonymization.reason, .disabledByUser)
        XCTAssertEqual(output.record.steps.palette.result?.maskApplied, false)
        XCTAssertEqual(output.storedImage, image)
        XCTAssertTrue(output.record.findings.contains { $0.templateId == "limitation.people_not_masked" })
        try AssessmentValidator.validate(output.record)
    }
    func testAnonymizerReturningUnblurredImageIsFailure() async throws {
        let output = try await run(FixtureAnonymizer(regions: [region(0.25, 0, 0.5, 1)], returnOriginal: true))
        XCTAssertEqual(output.record.steps.anonymization.status, .failed)
        XCTAssertEqual(output.record.steps.anonymization.reason, .anonymizationFailed)
        XCTAssertNil(output.storedImage)
    }
    func testUnchangedFlatMaskedAreaIsAccepted() throws {
        // A one-color masked area looks the same blurred or not, so "unchanged" is not a leak.
        let flat = SRGBImage(width: 8, height: 8, rgba: Array([UInt8]([10, 20, 30, 255]).repeated(64)))
        let regions = [region()]
        let mask = try PrivacyMasking.deriveMask(width: 8, height: 8, regions: regions)
        let output = AnonymizationOutput(result: .init(regions: regions, maskedShare: 0.5, mayBeIncomplete: true),
                                         mask: mask, anonymizedImage: flat)
        XCTAssertNoThrow(try PrivacyMasking.validate(output, against: flat))
    }
    /// 16×16 black/white checkerboard: lots of detail, so a real blur flattens it.
    private func checkerboard(alpha: UInt8 = 255) -> SRGBImage {
        let px: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
            let v: UInt8 = ((i % 16) + (i / 16)) % 2 == 0 ? 0 : 255
            return [v, v, v, alpha]
        }
        return .init(width: 16, height: 16, rgba: px)
    }
    private func output(_ img: SRGBImage, regions: [DetectedRegion], image anonymized: SRGBImage) throws -> AnonymizationOutput {
        let full = try PrivacyMasking.apply(img, regions: regions, radius: 4, mayBeIncomplete: true)
        return .init(result: full.result, mask: full.mask, anonymizedImage: anonymized)
    }
    func testRealBlurPassesObscuredCheck() throws {
        let img = checkerboard()
        let out = try PrivacyMasking.apply(img, regions: [region(0, 0, 0.5, 1), region(0.5, 0, 0.5, 0.5)],
                                           radius: 1, mayBeIncomplete: true)
        XCTAssertNoThrow(try PrivacyMasking.validate(out, against: img))
    }
    func testOneUnblurredRegionFailsEvenIfAnotherIsBlurred() throws {
        let img = checkerboard()
        let a = region(0, 0, 0.5, 1), b = region(0.5, 0, 0.5, 0.5)
        let onlyA = try PrivacyMasking.apply(img, regions: [a], radius: 4, mayBeIncomplete: true).anonymizedImage
        XCTAssertThrowsError(try PrivacyMasking.validate(output(img, regions: [a, b], image: onlyA), against: img))
    }
    func testChangingAFewMaskedPixelsIsNotObscuring() throws {
        let img = checkerboard()
        var touched = img.rgba
        for i in [0, 17, 34] { touched[i*4] = 128 }
        let out = try output(img, regions: [region(0, 0, 0.5, 1)], image: .init(width: 16, height: 16, rgba: touched))
        XCTAssertThrowsError(try PrivacyMasking.validate(out, against: img))
    }
    func testAlphaOnlyChangeIsNotObscuring() throws {
        let img = checkerboard(alpha: 128)
        var opaque = img.rgba
        for i in 0..<256 where (i % 16) < 8 { opaque[i*4+3] = 255 }
        let out = try output(img, regions: [region(0, 0, 0.5, 1)], image: .init(width: 16, height: 16, rgba: opaque))
        XCTAssertThrowsError(try PrivacyMasking.validate(out, against: img))
    }
    func testVisionUnsupportedErrorsMapToUnavailable() {
        for code in [8, 9, 16, 19, 21, 22] {
            XCTAssertTrue(PrivacyMasking.isVisionUnavailable(NSError(domain: "com.apple.Vision", code: code)), "code \(code)")
        }
        XCTAssertFalse(PrivacyMasking.isVisionUnavailable(NSError(domain: "other", code: 19)))
        XCTAssertFalse(PrivacyMasking.isVisionUnavailable(AnonymizationError.detectionFailed))
        #if canImport(Vision)
        XCTAssertEqual(VNErrorDomain, PrivacyMasking.visionErrorDomain)
        XCTAssertEqual(PrivacyMasking.visionUnavailableCodes, [VNErrorCode.notImplemented.rawValue,
            VNErrorCode.internalError.rawValue,
            VNErrorCode.unsupportedRevision.rawValue, VNErrorCode.unsupportedRequest.rawValue, 21, 22])
        if #available(macOS 14, iOS 17, *) {
            XCTAssertEqual(VNErrorCode.unsupportedComputeStage.rawValue, 21)
            XCTAssertEqual(VNErrorCode.unsupportedComputeDevice.rawValue, 22)
        }
        #endif
    }
    func testValidatorUsesRecordedMaxLongSide() async throws {
        var record = try await run(FixtureAnonymizer(regions: [region()])).record
        // A larger working copy (e.g. maxLongSide 2048) with consistent mask and palette counts.
        record.image.workingCopy.width = 2048; record.image.workingCopy.height = 1536
        record.image.workingCopy.maxLongSide = 2048
        record.steps.palette.result?.eligiblePixelCount = 2048 * 1536 / 2
        func errors(_ r: AssessmentRecord) -> [String] {
            do { try AssessmentValidator.validate(r); return [] }
            catch SafeSpaceError.validation(let messages) { return messages }
            catch { return ["\(error)"] }
        }
        XCTAssertFalse(errors(record).contains("Invalid privacy working dimensions"), "\(errors(record))")
        record.image.workingCopy.maxLongSide = 1024
        XCTAssertTrue(errors(record).contains("Invalid privacy working dimensions"))
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
    var returnOriginal = false
    var params: AnonymizationParams = .v1
    var methodName: String = VisionAnonymizer.methodName
    var methodVersion: Int { 1 }
    func encodedParameters() throws -> ContractJSON {
        try ContractJSON.encoding(params)
    }
    func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput {
        if cancel { throw CancellationError() }
        if let failure { throw failure }
        let output = try PrivacyMasking.apply(copy.image, regions: regions, radius: params.blurRadiusPx, mayBeIncomplete: true)
        if returnOriginal { return .init(result: output.result, mask: output.mask, anonymizedImage: copy.image) }
        if invalidOutput {
            return .init(result: .init(regions: [], maskedShare: 0.5, mayBeIncomplete: true),
                         mask: output.mask, anonymizedImage: output.anonymizedImage)
        }
        return output
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0..<n).flatMap { _ in self } }
}
