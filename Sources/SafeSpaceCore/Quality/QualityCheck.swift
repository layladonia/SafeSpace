import Foundation

// Task 19 (F4): photo-quality metrics. Contract §4.5 (JSON shape) and §5.4 (Swift API).
//
// Design decisions, recorded here so they live next to the code:
//
// 1. Pure Swift, integer-exact math. No Accelerate. The plan names Accelerate for the blur
//    metric, but main also builds on Windows (PR #7), where Accelerate does not exist. Two code
//    paths would give slightly different floats per platform, and S7 numbers have to regenerate
//    from the tagged build (S10). Every pixel-level step below uses integers. Doubles appear only
//    in the last few divisions, done in a fixed order, so results are bit-identical on iPhone,
//    Mac and Windows. At the 1024 px working-copy size a scalar pass takes a few milliseconds.
//
// 2. Quality warns only and never blocks analysis (decision log Oct 11, contract D3). `run`
//    therefore always returns `userContinued == true`.
//
// 3. The check runs on the whole working copy before anonymization (contract §3.1), so it
//    ignores the eligibility mask. It also ignores alpha: photos are opaque, and quality is about
//    what the camera captured.
//
// 4. Thresholds are the contract's v1 placeholders (`QualityParams.v1`). They are calibrated
//    after Task 22 finalizes the quality labels. Any change to a default threshold or to the math
//    here must bump `methodVersion`, so results from different tags are never mixed (§4.4).

public struct QualityMetrics: Codable, Sendable, Equatable {
    /// Mean relative luminance Y (linear sRGB, Rec. 709 / sRGB weights), 0–1, over all pixels.
    public var meanLuminance: Double
    /// Share of pixels whose R, G and B are all ≤ 2 (8-bit), i.e. crushed to black.
    public var clippedDarkShare: Double
    /// Share of pixels whose R, G and B are all ≥ 253 (8-bit), i.e. blown out to white.
    public var clippedBrightShare: Double
    /// Population variance of the 3×3 Laplacian of 8-bit luma. Lower means blurrier.
    public var blurLaplacianVariance: Double
    /// Long side of the ORIGINAL photo in pixels. Resolution is judged on the original because
    /// the working copy is always capped at 1024 (contract §4.5).
    public var originalLongSidePx: Int
    public init(meanLuminance: Double, clippedDarkShare: Double, clippedBrightShare: Double,
                blurLaplacianVariance: Double, originalLongSidePx: Int) {
        self.meanLuminance = meanLuminance; self.clippedDarkShare = clippedDarkShare
        self.clippedBrightShare = clippedBrightShare; self.blurLaplacianVariance = blurLaplacianVariance
        self.originalLongSidePx = originalLongSidePx
    }
}

/// Closed list (contract §4.5). Adding a case is a contract change (§12).
public enum QualityWarning: String, Codable, Sendable, CaseIterable {
    case tooDark = "too_dark", tooBright = "too_bright", overexposed, underexposed, blurry
    case lowResolution = "low_resolution"
}

public struct QualityResult: Codable, Sendable, Equatable {
    public let metrics: QualityMetrics
    /// Sorted by raw value, no duplicates (contract §4.5: "sorted"). Sorting by the JSON string,
    /// not by declaration order, makes the order easy to check from Python too.
    public let warnings: [QualityWarning]
    /// Always true in v1; recorded for S7's "user can always continue".
    public var userContinued: Bool
    public init(metrics: QualityMetrics, warnings: [QualityWarning], userContinued: Bool) {
        self.metrics = metrics; self.warnings = warnings; self.userContinued = userContinued
    }
}

public enum QualityCheck {
    public static let methodName = "quality_basic", methodVersion = 1

    /// Thrown when the metrics come out non-finite. The pipeline records it as
    /// `failed / quality_check_failed` instead of saving nonsense numbers.
    public struct InvalidMetrics: Error {}

    public static func run(_ copy: WorkingCopy, params: QualityParams = .v1) throws -> QualityResult {
        let original = copy.provenance.original
        let metrics = try measure(copy.image, originalLongSidePx: max(original.width, original.height))
        return QualityResult(metrics: metrics, warnings: warnings(for: metrics, params: params), userContinued: true)
    }

    /// Threshold rules. The params' names say which side of the threshold is a problem:
    /// a `…_max` value is the largest acceptable value, a `…_min` value the smallest. Only the two
    /// mean-luminance bounds are inclusive (dark when ≤ max, bright when ≥ min), because the
    /// param names describe the dark and bright ranges themselves. The other three describe the
    /// acceptable range, so only values outside it warn.
    /// The validator re-runs this to check that stored warnings agree with the stored metrics.
    public static func warnings(for m: QualityMetrics, params p: QualityParams) -> [QualityWarning] {
        var w: [QualityWarning] = []
        if m.meanLuminance <= p.darkMeanLuminanceMax { w.append(.tooDark) }
        if m.meanLuminance >= p.brightMeanLuminanceMin { w.append(.tooBright) }
        // Bright clipping is "overexposed" and dark clipping is "underexposed". These are
        // separate from too_bright/too_dark: a photo can have a normal average and still lose
        // detail in a window or a shadow.
        if m.clippedBrightShare > p.clippedShareMax { w.append(.overexposed) }
        if m.clippedDarkShare > p.clippedShareMax { w.append(.underexposed) }
        if m.blurLaplacianVariance < p.blurVarianceMin { w.append(.blurry) }
        if m.originalLongSidePx < p.minLongSidePx { w.append(.lowResolution) }
        return w.sorted { $0.rawValue < $1.rawValue }
    }

    /// Clipping thresholds from contract §4.5. They are fixed (not params) so the metric means
    /// the same thing in every saved file.
    static let darkClipMax: UInt8 = 2, brightClipMin: UInt8 = 253

    static func measure(_ image: SRGBImage, originalLongSidePx: Int) throws -> QualityMetrics {
        let w = image.width, h = image.height, n = w * h, px = image.rgba

        // Brightness and clipping in one pass. Brightness goes through per-channel 256-bin
        // histograms: mean(Y) = Σ weight_c · Σ_v count_c[v] · linear(v) / n. The integer counts
        // are exact and independent of pixel order, so the final sum is always done in the same
        // order.
        var histR = [Int](repeating: 0, count: 256), histG = histR, histB = histR
        var darkCount = 0, brightCount = 0
        // 8-bit luma for the blur metric, stored for the Laplacian pass below.
        var luma = [Int32](repeating: 0, count: n)
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let i = y * w + x, o = i * 4
                let r = px[o], g = px[o + 1], b = px[o + 2]
                histR[Int(r)] += 1; histG[Int(g)] += 1; histB[Int(b)] += 1
                if r <= darkClipMax && g <= darkClipMax && b <= darkClipMax { darkCount += 1 }
                if r >= brightClipMin && g >= brightClipMin && b >= brightClipMin { brightCount += 1 }
                luma[i] = luma8(r, g, b)
            }
        }
        let linear = linearLUT
        func channelMean(_ hist: [Int]) -> Double {
            var sum = 0.0
            for v in 0..<256 { sum += Double(hist[v]) * linear[v] }
            return sum / Double(n)
        }
        // sRGB / Rec. 709 luminance weights, the same primaries ColorSpace uses for XYZ.
        let meanY = 0.2126 * channelMean(histR) + 0.7152 * channelMean(histG) + 0.0722 * channelMean(histB)

        // Blur: variance of the 4-neighbour Laplacian kernel [0 1 0; 1 -4 1; 0 1 0] over every
        // pixel. Borders use reflect-101 (…2 1 | 0 1 2…), OpenCV's default. With the luma formula
        // in `luma8`, this equals `cv2.Laplacian(cv2.cvtColor(img, cv2.COLOR_RGB2GRAY), cv2.CV_64F).var()`,
        // so the team can cross-check values in Python without porting this code.
        // The sums are exact Int64: |L| ≤ 1020, so ΣL² ≤ ~1e12 at 1024 px, far from overflow.
        var sum: Int64 = 0, sumSq: Int64 = 0
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            let up = reflect101(y - 1, h) * w, row = y * w, down = reflect101(y + 1, h) * w
            for x in 0..<w {
                let left = reflect101(x - 1, w), right = reflect101(x + 1, w)
                let l = Int64(luma[up + x]) + Int64(luma[down + x]) + Int64(luma[row + left])
                      + Int64(luma[row + right]) - 4 * Int64(luma[row + x])
                sum += l; sumSq += l * l
            }
        }
        // Population variance (np.var's default), from the exact integer sums.
        let mean = Double(sum) / Double(n)
        let variance = max(0, Double(sumSq) / Double(n) - mean * mean)

        let metrics = QualityMetrics(meanLuminance: meanY, clippedDarkShare: Double(darkCount) / Double(n),
                                     clippedBrightShare: Double(brightCount) / Double(n),
                                     blurLaplacianVariance: variance, originalLongSidePx: originalLongSidePx)
        guard [metrics.meanLuminance, metrics.clippedDarkShare, metrics.clippedBrightShare,
               metrics.blurLaplacianVariance].allSatisfy(\.isFinite) else { throw InvalidMetrics() }
        return metrics
    }

    /// 8-bit luma with BT.601 weights, using OpenCV's exact fixed-point RGB→GRAY rounding
    /// (weights × 2^14, +2^13, >> 14). The contract only says "8-bit luma". We pick OpenCV's
    /// definition so blur values match the most common Python reference bit for bit.
    @inline(__always) static func luma8(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int32 {
        (Int32(r) * 4899 + Int32(g) * 9617 + Int32(b) * 1868 + 8192) >> 14
    }

    /// Reflect-101 border index. A 1-pixel-wide dimension has no neighbour to reflect to, so it
    /// reuses the pixel itself (OpenCV does the same).
    @inline(__always) static func reflect101(_ i: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        if i < 0 { return -i }
        if i >= n { return 2 * n - 2 - i }
        return i
    }

    /// sRGB-decoded value for each 8-bit code, using the same curve as the color conversions.
    static let linearLUT: [Double] = (0..<256).map { ColorSpace.sRGBToLinear(Double($0) / 255.0) }
}

// MARK: - Bridging to the record's opaque step payloads

// The quality step is stored as `StepRecord<ContractJSON>` (`AssessmentSteps` in
// PaletteRecordModels.swift). We convert through JSON here instead of retyping the step field,
// so this task doesn't edit the shared models file (Task 14's PR #12 has it open). The wire shape
// is identical either way.
extension ContractJSON {
    /// Encodes with the contract's snake_case encoder, matching how palette params are stored.
    static func encoding<T: Encodable>(_ value: T) throws -> ContractJSON {
        try JSONDecoder().decode(ContractJSON.self, from: AssessmentJSON.encoder().encode(value))
    }
    /// Reverse of `encoding`. It goes through the snake_case encoder and decoder, so it works on
    /// a freshly built value (snake_case keys) and on one decoded from disk (keys camelCased by
    /// the record decoder).
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try AssessmentJSON.decoder().decode(T.self, from: AssessmentJSON.encoder().encode(self))
    }
}

extension AssessmentRecord {
    /// Typed quality result for the app (Task 20 warning UI) and the CLI's images.csv columns.
    /// nil unless the quality step completed.
    public var qualityResult: QualityResult? {
        guard steps.quality.status == .completed else { return nil }
        return try? steps.quality.result?.decoded(as: QualityResult.self)
    }
}
