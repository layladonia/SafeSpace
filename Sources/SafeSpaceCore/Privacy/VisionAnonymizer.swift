import Foundation
#if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
import Vision
import CoreGraphics
import ImageIO
#endif

public struct AnonymizationParams: Codable, Sendable, Equatable {
    public var detectFaces = true
    public var detectPeople = true
    public var boxPadding = 0.10
    public var blurRadiusPx = 24
    public init() {}
    public static let v1 = AnonymizationParams()
    var isValid: Bool {
        (detectFaces || detectPeople) && boxPadding.isFinite && (0...1).contains(boxPadding)
            && (1...256).contains(blurRadiusPx)
    }
}
public enum AnonymizationError: Error, Sendable {
    case detectionUnavailable, detectionFailed, invalidParameters, invalidOutput
}

/// Faces plus full-body and upper-body rectangle detection. Detection is best effort,
/// not certification that all people have been removed. No files or source bytes retained.
public struct VisionAnonymizer: Anonymizer {
    public let params: AnonymizationParams
    public var methodName: String { "vision_faces_people" }
    public var methodVersion: Int { 1 }
    public init(params: AnonymizationParams = .v1) { self.params = params }
    public func encodedParameters() throws -> ContractJSON {
        try ContractJSON.encoding(params)
    }
    public func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput {
        guard params.isValid else { throw AnonymizationError.invalidParameters }
        try Task.checkCancellation()
        #if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
        guard #available(iOS 17, macOS 13, *) else { throw AnonymizationError.detectionUnavailable }
        let image = copy.image
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cg = CGImage(width: image.width, height: image.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw AnonymizationError.detectionFailed
        }
        let faces = VNDetectFaceRectanglesRequest()
        let fullPeople = VNDetectHumanRectanglesRequest()
        fullPeople.upperBodyOnly = false
        let upperPeople = VNDetectHumanRectanglesRequest()
        upperPeople.upperBodyOnly = true
        var requests: [VNRequest] = []
        if params.detectFaces { requests.append(faces) }
        if params.detectPeople { requests += [fullPeople, upperPeople] }
        do { try VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform(requests) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        var regions: [DetectedRegion] = []
        func add(_ kind: String, _ box: CGRect, _ confidence: Float) throws {
            let rect = try PrivacyMasking.topLeftPaddedRect(x: Double(box.minX), y: Double(box.minY),
                width: Double(box.width), height: Double(box.height), padding: params.boxPadding)
            regions.append(.init(kind: kind, rect: rect, confidence: Double(confidence)))
        }
        if params.detectFaces {
            guard let results = faces.results else { throw AnonymizationError.detectionFailed }
            for observation in results { try add("face", observation.boundingBox, observation.confidence) }
        }
        if params.detectPeople {
            guard let full = fullPeople.results, let upper = upperPeople.results else {
                throw AnonymizationError.detectionFailed
            }
            for observation in full + upper { try add("person", observation.boundingBox, observation.confidence) }
        }
        // Stable ordering; overlap is intentional and counted only once by the mask.
        regions.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            let a = [$0.rect.y, $0.rect.x, $0.rect.width, $0.rect.height, $0.confidence]
            let b = [$1.rect.y, $1.rect.x, $1.rect.width, $1.rect.height, $1.confidence]
            return a.lexicographicallyPrecedes(b)
        }
        // Conservative doubt heuristic: rectangle detectors can miss people, even when
        // both requests succeeded or found nothing. Always retain the contract limitation.
        return try PrivacyMasking.apply(image, regions: regions, radius: params.blurRadiusPx,
                                       mayBeIncomplete: true)
        #else
        throw AnonymizationError.detectionUnavailable
        #endif
    }
}

/// Pure mask/blur helpers also exercised on non-Apple platforms. Blur is a separable
/// box blur with radius in working-copy pixels, copied back ONLY inside the mask.
enum PrivacyMasking {
    static func topLeftPaddedRect(x: Double, y: Double, width: Double, height: Double,
                                 padding: Double) throws -> NormalizedRect {
        guard [x,y,width,height,padding].allSatisfy({ $0.isFinite }), width > 0, height > 0,
              padding >= 0 else { throw AnonymizationError.invalidOutput }
        let left = max(0, x - width * padding)
        let top = max(0, 1 - y - height - height * padding)
        let right = min(1, x + width + width * padding)
        let bottom = min(1, 1 - y + height * padding)
        guard right > left, bottom > top else { throw AnonymizationError.invalidOutput }
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }
    static func valid(_ region: DetectedRegion) -> Bool {
        let r = region.rect
        return ["face", "person"].contains(region.kind) && region.confidence.isFinite
            && (0...1).contains(region.confidence)
            && [r.x,r.y,r.width,r.height].allSatisfy({ $0.isFinite })
            && r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0
            && r.x + r.width <= 1 + 1e-12 && r.y + r.height <= 1 + 1e-12
    }
    static func apply(_ image: SRGBImage, regions: [DetectedRegion], radius: Int,
                      mayBeIncomplete: Bool) throws -> AnonymizationOutput {
        guard (1...256).contains(radius), regions.allSatisfy(valid) else {
            throw AnonymizationError.invalidOutput
        }
        try Task.checkCancellation()
        let mask = EligibilityMask.all(width: image.width, height: image.height).excluding(regions.map(\.rect))
        let excluded = image.width * image.height - mask.eligibleCount
        let result = AnonymizationResult(regions: regions,
            maskedShare: Double(excluded) / Double(image.width * image.height), mayBeIncomplete: mayBeIncomplete)
        guard excluded > 0 else { return .init(result: result, mask: mask, anonymizedImage: image) }
        let w = image.width, h = image.height
        var horizontal = image.rgba
        var blurred = image.rgba
        // Clipped windows (no opposite-edge wrap or out-of-image samples).
        for y in 0..<h {
            try Task.checkCancellation()
            for c in 0..<3 {
                var sum = 0, right = -1, left = 0
                for x in 0..<w {
                    let end = min(w - 1, x + radius), start = max(0, x - radius)
                    while right < end { right += 1; sum += Int(image.rgba[(y*w+right)*4+c]) }
                    while left < start { sum -= Int(image.rgba[(y*w+left)*4+c]); left += 1 }
                    horizontal[(y*w+x)*4+c] = UInt8((sum + (end-start+1)/2) / (end-start+1))
                }
            }
        }
        for x in 0..<w {
            try Task.checkCancellation()
            for c in 0..<3 {
                var sum = 0, bottom = -1, top = 0
                for y in 0..<h {
                    let end = min(h - 1, y + radius), start = max(0, y - radius)
                    while bottom < end { bottom += 1; sum += Int(horizontal[(bottom*w+x)*4+c]) }
                    while top < start { sum -= Int(horizontal[(top*w+x)*4+c]); top += 1 }
                    if !mask.eligible[y*w+x] {
                        blurred[(y*w+x)*4+c] = UInt8((sum + (end-start+1)/2) / (end-start+1))
                        blurred[(y*w+x)*4+3] = 255
                    }
                }
            }
        }
        return .init(result: result, mask: mask, anonymizedImage: .init(width: w, height: h, rgba: blurred))
    }
    static func validate(_ output: AnonymizationOutput, against image: SRGBImage) throws {
        guard output.anonymizedImage.width == image.width, output.anonymizedImage.height == image.height,
              output.mask.width == image.width, output.mask.height == image.height,
              output.result.regions.allSatisfy(valid) else { throw AnonymizationError.invalidOutput }
        let expected = EligibilityMask.all(width: image.width, height: image.height)
            .excluding(output.result.regions.map(\.rect))
        let share = 1 - Double(expected.eligibleCount) / Double(image.width * image.height)
        guard expected == output.mask, output.result.maskedShare.isFinite,
              abs(share - output.result.maskedShare) <= 1e-12,
              (share > 0) == !output.result.regions.isEmpty else { throw AnonymizationError.invalidOutput }
        for i in expected.eligible.indices where expected.eligible[i] {
            if i % 8192 == 0 { try Task.checkCancellation() }
            for c in 0..<4 where image.rgba[i*4+c] != output.anonymizedImage.rgba[i*4+c] {
                throw AnonymizationError.invalidOutput
            }
        }
    }
}
