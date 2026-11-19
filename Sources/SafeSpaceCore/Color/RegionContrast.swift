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

public enum ContrastDifferenceBand: Sendable, Equatable {
    case imperceptible
    case veryLow
    case moderate
    case clear
    case high
    case veryHigh

    public init?(deltaE: Double) {
        guard deltaE.isFinite, deltaE >= 0 else { return nil }
        if deltaE <= 1 {
            self = .imperceptible
        } else if deltaE <= 5 {
            self = .veryLow
        } else if deltaE <= 15 {
            self = .moderate
        } else if deltaE <= 30 {
            self = .clear
        } else if deltaE <= 60 {
            self = .high
        } else {
            self = .veryHigh
        }
    }

    public var title: String {
        switch self {
        case .imperceptible: "Imperceptible"
        case .veryLow: "Very low contrast"
        case .moderate: "Moderate difference"
        case .clear: "Clear difference"
        case .high: "High contrast / distinct"
        case .veryHigh: "Very high contrast"
        }
    }

    public var guidance: String {
        switch self {
        case .imperceptible: "A very small measured color difference."
        case .veryLow: "A small measured color difference."
        case .moderate: "A moderate measured difference between the selected areas."
        case .clear: "A clear measured difference between the selected areas."
        case .high: "A large measured difference between the selected areas."
        case .veryHigh: "A very large measured difference between the selected areas."
        }
    }
}

public enum RegionContrastError: Error, Sendable {
    /// Fewer than `minEligiblePixels` eligible pixels landed in this region (contract §4.8);
    /// the UI should ask the user to draw a larger box.
    case regionTooSmall(region: Int)
}

public enum RegionContrast {
    public static let legacyMethodName = "region_mean_ciede2000"
    public static let methodName = "region_median_ciede2000"
    public static let methodVersion = 1
    public static let defaultMinEligiblePixels = 100

    public static func measure(
        _ image: SRGBImage,
        mask: EligibilityMask,
        region1: NormalizedRect,
        region2: NormalizedRect,
        minEligiblePixels: Int = defaultMinEligiblePixels,
        label: String? = nil,
        useLegacyMean: Bool = false
    ) throws -> ContrastMeasurement {
        let a = try representativeCIELAB(image: image, mask: mask, rect: region1, regionNumber: 1, minEligiblePixels: minEligiblePixels, useLegacyMean: useLegacyMean)
        let b = try representativeCIELAB(image: image, mask: mask, rect: region2, regionNumber: 2, minEligiblePixels: minEligiblePixels, useLegacyMean: useLegacyMean)
        let deltaE = ColorDifference.ciede2000(
            PerceptualColor(L: a.cielab.l, a: a.cielab.a, b: a.cielab.b),
            PerceptualColor(L: b.cielab.l, a: b.cielab.a, b: b.cielab.b)
        )
        return ContrastMeasurement(measurementId: UUID().uuidString.lowercased(),
                                   createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                                   label: label, region1: a, region2: b, deltaE: deltaE)
    }

    private static func representativeCIELAB(
        image: SRGBImage, mask: EligibilityMask, rect: NormalizedRect, regionNumber: Int, minEligiblePixels: Int, useLegacyMean: Bool
    ) throws -> RegionColorAverage {
        precondition(mask.width == image.width && mask.height == image.height)
        let bounds = rect.pixelBounds(width: image.width, height: image.height)
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        var lightness: [Double] = [], channelsA: [Double] = [], channelsB: [Double] = []
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
                if useLegacyMean {
                    sumL += lab.L; sumA += lab.a; sumB += lab.b
                } else {
                    lightness.append(lab.L); channelsA.append(lab.a); channelsB.append(lab.b)
                }
                count += 1
            }
        }
        guard count > 0, count >= minEligiblePixels else { throw RegionContrastError.regionTooSmall(region: regionNumber) }
        let n = Double(count)
        func median(_ values: inout [Double]) -> Double {
            values.sort()
            let middle = values.count / 2
            return values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        }
        let representative = useLegacyMean
            ? LabValue(l: sumL / n, a: sumA / n, b: sumB / n)
            : LabValue(l: median(&lightness), a: median(&channelsA), b: median(&channelsB))
        return RegionColorAverage(rect: rect, pixelCount: count, cielab: representative)
    }
}
