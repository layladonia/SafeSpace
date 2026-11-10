import XCTest
@testable import SafeSpaceCore

final class QualityCheckTests: XCTestCase {
    private func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> [UInt8]) -> SRGBImage {
        var rgba: [UInt8] = []
        for y in 0..<h { for x in 0..<w { rgba += pixel(x, y) + [255] } }
        return SRGBImage(width: w, height: h, rgba: rgba)
    }
    private func solid(_ v: UInt8, _ w: Int = 8, _ h: Int = 8) -> SRGBImage { image(w, h) { _, _ in [v, v, v] } }
    private let producer = Producer(kind: "cli", appVersion: nil, coreVersion: SafeSpaceCore.version, device: "test", os: "test")

    /// Independent reference: pads the luma grid explicitly (reflect-101) and uses Doubles,
    /// mirroring what `cv2.Laplacian(gray, cv2.CV_64F).var()` does, so the integer code is
    /// checked against a different formulation, not against itself.
    private func referenceVariance(_ img: SRGBImage) -> Double {
        let w = img.width, h = img.height
        func luma(_ x: Int, _ y: Int) -> Double {
            func r(_ i: Int, _ n: Int) -> Int { n == 1 ? 0 : (i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i)) }
            let o = (r(y, h) * w + r(x, w)) * 4
            return Double(QualityCheck.luma8(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]))
        }
        var values: [Double] = []
        for y in 0..<h { for x in 0..<w {
            values.append(luma(x, y - 1) + luma(x, y + 1) + luma(x - 1, y) + luma(x + 1, y) - 4 * luma(x, y))
        } }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    func testLumaMatchesOpenCVFixedPoint() {
        // cv2.cvtColor(..., COLOR_RGB2GRAY) values for pure primaries, white and black.
        XCTAssertEqual(QualityCheck.luma8(255, 0, 0), 76)
        XCTAssertEqual(QualityCheck.luma8(0, 255, 0), 150)
        XCTAssertEqual(QualityCheck.luma8(0, 0, 255), 29)
        XCTAssertEqual(QualityCheck.luma8(255, 255, 255), 255)
        XCTAssertEqual(QualityCheck.luma8(0, 0, 0), 0)
    }

    func testSolidImagesBrightnessAndClipping() throws {
        let black = try QualityCheck.measure(solid(0), originalLongSidePx: 4000)
        XCTAssertEqual(black.meanLuminance, 0)
        XCTAssertEqual(black.clippedDarkShare, 1); XCTAssertEqual(black.clippedBrightShare, 0)
        XCTAssertEqual(black.blurLaplacianVariance, 0)
        let white = try QualityCheck.measure(solid(255), originalLongSidePx: 4000)
        XCTAssertEqual(white.meanLuminance, 1, accuracy: 1e-12)
        XCTAssertEqual(white.clippedBrightShare, 1); XCTAssertEqual(white.clippedDarkShare, 0)
        // Mid-gray 128 → linear 0.21586 (sRGB curve), the standard reference value.
        let gray = try QualityCheck.measure(solid(128), originalLongSidePx: 4000)
        XCTAssertEqual(gray.meanLuminance, 0.21586, accuracy: 1e-5)
        // Clipping thresholds are inclusive at 2 and 253, and every channel must be clipped.
        let edges = image(4, 1) { x, _ in [[2, 2, 2], [253, 253, 253], [3, 2, 2], [255, 255, 252]][x] }
        let e = try QualityCheck.measure(edges, originalLongSidePx: 4000)
        XCTAssertEqual(e.clippedDarkShare, 0.25); XCTAssertEqual(e.clippedBrightShare, 0.25)
    }

    func testBlurVarianceMatchesReference() throws {
        let checker = image(7, 5) { x, y in (x + y) % 2 == 0 ? [255, 255, 255] : [0, 0, 0] }
        let noise = image(13, 9) { x, y in [UInt8((x * 37 + y * 91) % 256), UInt8((x * 11 + y * 53) % 256), UInt8((x * y * 7) % 256)] }
        let thin = image(9, 1) { x, _ in [UInt8(x * 30), 0, 0] }   // 1-pixel dimension
        for img in [checker, noise, thin, solid(77, 1, 1)] {
            let m = try QualityCheck.measure(img, originalLongSidePx: 4000)
            XCTAssertEqual(m.blurLaplacianVariance, referenceVariance(img), accuracy: 1e-9)
        }
        // A sharp checkerboard is far above the blur threshold; a flat image is at zero.
        XCTAssertGreaterThan(try QualityCheck.measure(checker, originalLongSidePx: 4000).blurLaplacianVariance, 1000)
    }

    func testBlurIsInvariantToTranspose() throws {
        // The 4-neighbour kernel and reflect-101 border are symmetric, so rotating or transposing
        // a photo must not change its blur score.
        let a = image(11, 6) { x, y in [UInt8((x * 41 + y * 13) % 256), UInt8(x * 20), UInt8(y * 40)] }
        let t = image(6, 11) { x, y in
            let o = (x * 11 + y) * 4
            return [a.rgba[o], a.rgba[o + 1], a.rgba[o + 2]]
        }
        XCTAssertEqual(try QualityCheck.measure(a, originalLongSidePx: 1).blurLaplacianVariance,
                       try QualityCheck.measure(t, originalLongSidePx: 1).blurLaplacianVariance)
    }

    func testWarningRulesBoundariesAndOrder() {
        let p = QualityParams.v1
        func w(_ lum: Double, dark: Double = 0, bright: Double = 0, blur: Double = 500, side: Int = 4000) -> [QualityWarning] {
            QualityCheck.warnings(for: .init(meanLuminance: lum, clippedDarkShare: dark, clippedBrightShare: bright,
                                             blurLaplacianVariance: blur, originalLongSidePx: side), params: p)
        }
        XCTAssertEqual(w(0.5), [])
        XCTAssertEqual(w(p.darkMeanLuminanceMax), [.tooDark])          // inclusive
        XCTAssertEqual(w(p.brightMeanLuminanceMin), [.tooBright])      // inclusive
        XCTAssertEqual(w(0.5, bright: p.clippedShareMax), [])          // exclusive
        XCTAssertEqual(w(0.5, blur: p.blurVarianceMin), [])            // exclusive
        XCTAssertEqual(w(0.5, side: p.minLongSidePx), [])              // exclusive
        // Every warning at once comes out sorted by its JSON string.
        let all = w(p.darkMeanLuminanceMax / 2, dark: 0.5, bright: 0.5, blur: 0, side: 10)
        XCTAssertEqual(all.map(\.rawValue), ["blurry", "low_resolution", "overexposed", "too_dark", "underexposed"])
    }

    func testPipelineCompletesAndRoundTrips() async throws {
        // A 16 px photo is low resolution, flat (blurry) and dark, so it exercises the warnings,
        // the quality findings and the limitation.
        let data = solid(40, 16, 16).pngData()
        let output = try await AssessmentPipeline.run(imageData: data, source: .file, roomID: "cli", producer: producer)
        let r = output.record
        XCTAssertEqual(r.steps.quality.status, .completed)
        XCTAssertEqual(r.steps.quality.method?.name, "quality_basic")
        let q = try XCTUnwrap(r.qualityResult)
        XCTAssertEqual(q.warnings, [.blurry, .lowResolution, .tooDark])
        XCTAssertEqual(q.metrics.originalLongSidePx, 16)
        XCTAssertTrue(q.userContinued)
        XCTAssertEqual(r.overallState, .complete)
        XCTAssertEqual(r.findings.filter { $0.kind == .quality }.map(\.templateId),
                       ["quality.blurry", "quality.low_resolution", "quality.too_dark"])
        XCTAssertTrue(r.findings.contains { $0.templateId == "limitation.quality_warning" })
        XCTAssertFalse(r.findings.contains { $0.templateId == "limitation.quality_not_checked" })
        // Save/reopen keeps the quality result exactly (S6), including after the snake_case round trip.
        let reopened = try AssessmentJSON.decode(AssessmentJSON.encode(r))
        XCTAssertEqual(reopened, r)
        XCTAssertEqual(reopened.qualityResult, q)
        // The wire shape is exact: contract §4.5 keys only.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: AssessmentJSON.encoder().encode(r)) as? [String: Any])
        let step = try XCTUnwrap((root["steps"] as? [String: Any])?["quality"] as? [String: Any])
        let metrics = try XCTUnwrap((step["result"] as? [String: Any])?["metrics"] as? [String: Any])
        XCTAssertEqual(Set(metrics.keys), ["mean_luminance", "clipped_dark_share", "clipped_bright_share",
                                           "blur_laplacian_variance", "original_long_side_px"])
    }

    func testValidatorRejectsInconsistentQuality() async throws {
        let base = try await AssessmentPipeline.run(imageData: solid(40, 16, 16).pngData(), source: .file,
                                                    roomID: "cli", producer: producer).record
        let q = try XCTUnwrap(base.qualityResult)
        // Warnings that don't follow from the stored metrics and params.
        var r = base
        r.steps.quality.result = try ContractJSON.encoding(QualityResult(metrics: q.metrics, warnings: [], userContinued: true))
        XCTAssertThrowsError(try AssessmentValidator.validate(r))
        // user_continued must be true in v1.
        r = base
        r.steps.quality.result = try ContractJSON.encoding(QualityResult(metrics: q.metrics, warnings: q.warnings, userContinued: false))
        XCTAssertThrowsError(try AssessmentValidator.validate(r))
        // Missing quality limitation.
        r = base
        r.findings.removeAll { $0.templateId == "limitation.quality_warning" }
        XCTAssertThrowsError(try AssessmentValidator.validate(r))
        // Unknown key inside metrics is rejected on read.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: AssessmentJSON.encode(base)) as? [String: Any])
        var steps = object["steps"] as! [String: Any], quality = steps["quality"] as! [String: Any]
        var result = quality["result"] as! [String: Any], metrics = result["metrics"] as! [String: Any]
        metrics["histogram"] = [1, 2, 3]
        result["metrics"] = metrics; quality["result"] = result; steps["quality"] = quality; object["steps"] = steps
        XCTAssertThrowsError(try AssessmentJSON.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testDisabledQualityIsSkipped() async throws {
        var options = PipelineOptions(); options.runQuality = false
        let r = try await AssessmentPipeline.run(imageData: solid(40, 16, 16).pngData(), source: .file,
                                                 roomID: "cli", producer: producer, options: options).record
        XCTAssertEqual(r.steps.quality.status, .skipped)
        XCTAssertEqual(r.steps.quality.reason, .disabledByUser)
        XCTAssertNil(r.qualityResult)
        XCTAssertTrue(r.findings.contains { $0.templateId == "limitation.quality_not_checked" })
        try AssessmentValidator.validate(r)
    }

    func testQualityTemplatesHaveNoBannedTerms() {
        let m = QualityMetrics(meanLuminance: 0.5, clippedDarkShare: 0.003, clippedBrightShare: 0.31,
                               blurLaplacianVariance: 12, originalLongSidePx: 480)
        for warning in QualityWarning.allCases {
            let text = Findings.qualityTemplate(warning, m).text
            XCTAssertFalse(Findings.containsBannedTerm(text), text)
        }
        XCTAssertTrue(Findings.qualityTemplate(.overexposed, m).text.hasPrefix("About 31%"))
        XCTAssertTrue(Findings.qualityTemplate(.underexposed, m).text.hasPrefix("Less than 1%"))
    }

    /// Task 19 "done when": the metrics return values on the room-photo set. This loads each
    /// photo exactly as the pipeline does and prints one row per image for the PR / calibration.
    /// Opt-in (`SAFESPACE_DATASET_TESTS=1 swift test --filter testMetricsOnRoomPhotoSet`): decoding
    /// ~47 full-size photos takes about a minute in a debug build, too slow for every `swift test`.
    func testMetricsOnRoomPhotoSet() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAFESPACE_DATASET_TESTS"] == "1",
                          "Set SAFESPACE_DATASET_TESTS=1 to run the room-photo dataset pass")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Datasets/room-photos/images")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        print("QUALITY image,mean_luminance,clipped_dark_share,clipped_bright_share,blur_laplacian_variance,original_long_side_px,warnings")
        for file in files {
            let result = try QualityCheck.run(ImageLoader.load(url: file))
            let m = result.metrics
            XCTAssertTrue((0...1).contains(m.meanLuminance) && m.blurLaplacianVariance.isFinite, file.lastPathComponent)
            print(String(format: "QUALITY %@,%.6f,%.6f,%.6f,%.6f,%d,%@", file.lastPathComponent, m.meanLuminance,
                         m.clippedDarkShare, m.clippedBrightShare, m.blurLaplacianVariance, m.originalLongSidePx,
                         result.warnings.map(\.rawValue).joined(separator: ";")))
        }
    }
}
