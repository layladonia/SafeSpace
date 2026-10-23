import Foundation
import CoreGraphics
import ImageIO

public struct EligibilityMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let eligible: [Bool]
    public init(width: Int, height: Int, eligible: [Bool]) {
        precondition(width > 0 && height > 0 && eligible.count == width * height)
        self.width = width; self.height = height; self.eligible = eligible
    }
    public static func all(width: Int, height: Int) -> EligibilityMask {
        .init(width: width, height: height, eligible: Array(repeating: true, count: width * height))
    }
    public var eligibleCount: Int { eligible.reduce(0) { $0 + ($1 ? 1 : 0) } }
    public func excluding(_ rects: [NormalizedRect]) -> EligibilityMask {
        var values = eligible
        for rect in rects {
            let bounds = rect.pixelBounds(width: width, height: height)
            for y in bounds.y0..<bounds.y1 {
                for x in bounds.x0..<bounds.x1 { values[y * width + x] = false }
            }
        }
        return .init(width: width, height: height, eligible: values)
    }
    public func pngData() -> Data {
        PNGCodec.encode(width: width, height: height, bytes: eligible.map { $0 ? 255 : 0 }, gray: true)
    }
    public init(pngData: Data) throws {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SafeSpaceError.load(.unreadableData)
        }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            c.interpolationQuality = .none
            c.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))); return true
        }
        guard ok else { throw SafeSpaceError.load(.unreadableData) }
        self.init(width: w, height: h, eligible: bytes.map { $0 >= 128 })
    }

    // Compatibility only for the old ImagePipeline API; new code uses the Bool mask.
    @available(*, deprecated, message: "Use PaletteExtractor with EligibilityMask instead")
    public static func apply(mask: Pixels?, to image: Pixels) -> Pixels {
        guard let mask else { return image }
        guard mask.width == image.width, mask.height == image.height,
              mask.bytes.count == image.bytes.count else { return image }
        var copy = image
        for i in 0..<(image.width * image.height) {
            if mask.bytes[i * 4] == 0 { copy.bytes[i * 4 + 3] = 0 }
        }
        return copy
    }
}
