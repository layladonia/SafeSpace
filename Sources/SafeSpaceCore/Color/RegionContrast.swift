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

public struct RegionContrastResult: Codable, Equatable, Sendable {
    public var colorSpace: String
    public var formula: String
    public var region1: RegionColorAverage
    public var region2: RegionColorAverage
    public var deltaE: Double
}

public enum RegionContrastError: Error, Sendable {
    case noEligiblePixels(region: Int)
}

public enum RegionContrast {
    public static func compare(
        _ image: SRGBImage,
        mask: EligibilityMask,
        region1: NormalizedRect,
        region2: NormalizedRect
    ) throws -> RegionContrastResult {
        let a = try averageCIELAB(image: image, mask: mask, rect: region1, regionNumber: 1)
        let b = try averageCIELAB(image: image, mask: mask, rect: region2, regionNumber: 2)
        let deltaE = ColorDifference.ciede2000(
            PerceptualColor(L: a.cielab.l, a: a.cielab.a, b: a.cielab.b),
            PerceptualColor(L: b.cielab.l, a: b.cielab.a, b: b.cielab.b)
        )
        return RegionContrastResult(colorSpace: "cielab", formula: "ciede2000", region1: a, region2: b, deltaE: deltaE)
    }

    private static func averageCIELAB(
        image: SRGBImage, mask: EligibilityMask, rect: NormalizedRect, regionNumber: Int
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
        guard count > 0 else { throw RegionContrastError.noEligiblePixels(region: regionNumber) }
        let n = Double(count)
        return RegionColorAverage(rect: rect, pixelCount: count, cielab: LabValue(l: sumL / n, a: sumA / n, b: sumB / n))
    }
}
