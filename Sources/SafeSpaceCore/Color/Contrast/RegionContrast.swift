import Foundation

public enum RegionSide: String, Sendable, Equatable {
    case a, b
}

public struct ContrastRegion: Codable, Sendable, Equatable {
    public var rect: NormalizedRect
    public var pixelCount: Int
    public var eligiblePixelCount: Int
    public var meanCielab: LabValue
    public var meanHex: String
}

public struct ContrastMeasurement: Codable, Sendable, Equatable, Identifiable {
    public var measurementId: String
    public var createdAt: Date
    public var label: String?
    public var regionA: ContrastRegion
    public var regionB: ContrastRegion
    public var deltaE2000: Double
    public var id: String { measurementId }

    public init(measurementId: String, createdAt: Date, label: String?, regionA: ContrastRegion,
                regionB: ContrastRegion, deltaE2000: Double) {
        self.measurementId = measurementId
        self.createdAt = createdAt
        self.label = label
        self.regionA = regionA
        self.regionB = regionB
        self.deltaE2000 = deltaE2000
    }

    enum CodingKeys: String, CodingKey {
        case measurementId, createdAt, label, regionA, regionB
        case deltaE2000 = "deltaE_2000"
    }

    private enum DecodeKeys: String, CodingKey {
        case measurementId, createdAt, label, regionA, regionB, deltaE2000
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodeKeys.self)
        measurementId = try container.decode(String.self, forKey: .measurementId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        regionA = try container.decode(ContrastRegion.self, forKey: .regionA)
        regionB = try container.decode(ContrastRegion.self, forKey: .regionB)
        deltaE2000 = try container.decode(Double.self, forKey: .deltaE2000)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(measurementId, forKey: .measurementId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(label, forKey: .label)
        try container.encode(regionA, forKey: .regionA)
        try container.encode(regionB, forKey: .regionB)
        try container.encode(deltaE2000, forKey: .deltaE2000)
    }
}

public struct ContrastResult: Codable, Sendable, Equatable {
    public var measurements: [ContrastMeasurement]
}

extension AssessmentRecord {
    var contrastResult: ContrastResult? {
        guard steps.contrast.status == .completed else { return nil }
        return try? steps.contrast.result?.decoded(as: ContrastResult.self)
    }
}

public enum RegionContrast {
    public static let methodName = "region_mean_ciede2000"
    public static let methodVersion = 1

    public static func measure(image: SRGBImage, mask: EligibilityMask,
                               a: NormalizedRect, b: NormalizedRect,
                               minEligiblePixels: Int = 100) throws -> ContrastMeasurement {
        guard image.width == mask.width, image.height == mask.height else {
            throw SafeSpaceError.validation(["Image and eligibility mask dimensions differ"])
        }
        guard minEligiblePixels > 0 else {
            throw SafeSpaceError.validation(["Minimum eligible pixel count must be positive"])
        }
        let regionA = try summarize(image: image, mask: mask, rect: a, side: .a,
                                    minEligiblePixels: minEligiblePixels)
        let regionB = try summarize(image: image, mask: mask, rect: b, side: .b,
                                    minEligiblePixels: minEligiblePixels)
        let labA = PerceptualColor(L: regionA.meanCielab.l, a: regionA.meanCielab.a, b: regionA.meanCielab.b)
        let labB = PerceptualColor(L: regionB.meanCielab.l, a: regionB.meanCielab.a, b: regionB.meanCielab.b)
        return ContrastMeasurement(measurementId: UUID().uuidString.lowercased(), createdAt: Date(),
                                  label: nil, regionA: regionA, regionB: regionB,
                                  deltaE2000: ColorDifference.ciede2000(labA, labB))
    }

    private static func summarize(image: SRGBImage, mask: EligibilityMask, rect: NormalizedRect,
                                  side: RegionSide, minEligiblePixels: Int) throws -> ContrastRegion {
        guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= 1, rect.y + rect.height <= 1 else {
            throw SafeSpaceError.regionOutOfBounds(region: side)
        }
        let bounds = rect.pixelBounds(width: image.width, height: image.height)
        let pixelCount = (bounds.x1 - bounds.x0) * (bounds.y1 - bounds.y0)
        var count = 0
        var lightness = 0.0, axisA = 0.0, axisB = 0.0
        var red = 0, green = 0, blue = 0
        for y in bounds.y0..<bounds.y1 {
            for x in bounds.x0..<bounds.x1 {
                let i = y * image.width + x
                guard mask.eligible[i] else { continue }
                let offset = i * 4
                let r = image.rgba[offset], g = image.rgba[offset + 1], b = image.rgba[offset + 2]
                let lab = ColorSpace.sRGBToCIELAB(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
                count += 1
                lightness += lab.L; axisA += lab.a; axisB += lab.b
                red += Int(r); green += Int(g); blue += Int(b)
            }
        }
        guard count >= minEligiblePixels else {
            throw SafeSpaceError.regionTooSmall(region: side, eligiblePixels: count)
        }
        let divisor = Double(count)
        let hex = String(format: "#%02X%02X%02X",
                         (red + count / 2) / count, (green + count / 2) / count, (blue + count / 2) / count)
        return ContrastRegion(rect: rect, pixelCount: pixelCount, eligiblePixelCount: count,
                              meanCielab: LabValue(l: lightness / divisor, a: axisA / divisor, b: axisB / divisor),
                              meanHex: hex)
    }
}
