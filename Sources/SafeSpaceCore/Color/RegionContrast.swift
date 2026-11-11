// Averages two user-selected regions into CIELAB and feeds the two means to the existing
// CIEDE2000 formula (ColorDifference.ciede2000). This file is the middle step between a
// region-selection UI (which only produces two NormalizedRect boxes over a photo) and the
// already-implemented, already-tested color math in ColorSpace.swift / ColorDifference.swift.
import Foundation

public struct RegionColorAverage: Codable, Equatable, Sendable {
    public var rect: NormalizedRect
    public var pixelCount: Int
    public var cielab: LabValue
}

/// One comparison between two regions (contract §4.8). `AssessmentSteps.contrast.result`
/// holds a growing array of these: the first comes from the initial pipeline run if regions
/// were supplied up front, later ones are appended by `AssessmentPipeline.addContrast`.
public struct ContrastMeasurement: Codable, Equatable, Sendable, Identifiable {
    public var measurementId: String
    public var createdAt: Date
    public var label: String?
    public var region1: RegionColorAverage
    public var region2: RegionColorAverage
    public var deltaE: Double
    public var id: String { measurementId }
    enum CodingKeys: String, CodingKey { case measurementId, createdAt, label, region1, region2, deltaE }
    // `encode(_:forKey:)`, not `encodeIfPresent`, so a nil label is written as `null` and the
    // key is never missing — EarlyBuildWireCheck in PaletteRecordValidation.swift requires the
    // exact key set on every measurement.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(measurementId, forKey: .measurementId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(label, forKey: .label)
        try c.encode(region1, forKey: .region1)
        try c.encode(region2, forKey: .region2)
        try c.encode(deltaE, forKey: .deltaE)
    }
}

public struct RegionContrastResult: Codable, Equatable, Sendable {
    public var colorSpace: String
    public var formula: String
    public var measurements: [ContrastMeasurement]
}

public enum RegionContrastError: Error, Sendable {
    /// Fewer than `minEligiblePixels` eligible pixels landed in this region (contract §4.8);
    /// the UI should ask the user to draw a larger box.
    case regionTooSmall(region: Int)
}

public enum RegionContrast {
    public static let methodName = "region_mean_ciede2000"
    public static let methodVersion = 1
    public static let defaultMinEligiblePixels = 100

    public static func measure(
        _ image: SRGBImage,
        mask: EligibilityMask,
        region1: NormalizedRect,
        region2: NormalizedRect,
        minEligiblePixels: Int = defaultMinEligiblePixels,
        label: String? = nil
    ) throws -> ContrastMeasurement {
        let a = try averageCIELAB(image: image, mask: mask, rect: region1, regionNumber: 1, minEligiblePixels: minEligiblePixels)
        let b = try averageCIELAB(image: image, mask: mask, rect: region2, regionNumber: 2, minEligiblePixels: minEligiblePixels)
        let deltaE = ColorDifference.ciede2000(
            PerceptualColor(L: a.cielab.l, a: a.cielab.a, b: a.cielab.b),
            PerceptualColor(L: b.cielab.l, a: b.cielab.a, b: b.cielab.b)
        )
        return ContrastMeasurement(measurementId: UUID().uuidString.lowercased(),
                                   createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                                   label: label, region1: a, region2: b, deltaE: deltaE)
    }

    private static func averageCIELAB(
        image: SRGBImage, mask: EligibilityMask, rect: NormalizedRect, regionNumber: Int, minEligiblePixels: Int
    ) throws -> RegionColorAverage {
        precondition(mask.width == image.width && mask.height == image.height)
        let bounds = rect.pixelBounds(width: image.width, height: image.height)
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        var count = 0
        for y in bounds.y0..<bounds.y1 {
            for x in bounds.x0..<bounds.x1 {
                let idx = y * image.width + x
                guard mask.eligible[idx] else { continue }
                let o = idx * 4
                let lab = ColorSpace.sRGBToCIELAB(
                    r: Double(image.rgba[o]) / 255.0,
                    g: Double(image.rgba[o + 1]) / 255.0,
                    b: Double(image.rgba[o + 2]) / 255.0
                )
                sumL += lab.L; sumA += lab.a; sumB += lab.b
                count += 1
            }
        }
        guard count >= minEligiblePixels else { throw RegionContrastError.regionTooSmall(region: regionNumber) }
        let n = Double(count)
        return RegionColorAverage(rect: rect, pixelCount: count, cielab: LabValue(l: sumL / n, a: sumA / n, b: sumB / n))
    }
}
