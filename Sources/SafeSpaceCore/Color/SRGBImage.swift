import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct SRGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        self.width = width; self.height = height; self.rgba = rgba
    }
    public func pngData() -> Data { PNGCodec.encode(width: width, height: height, bytes: rgba, gray: false) }
    public init(pngData: Data) throws {
        self = try ImageLoader.load(data: pngData, source: .file, maxLongSide: Int.max).image
    }
}
public struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    /// Contract §4.8 bounds (x1, y1 exclusive), clamped to the image. A box that runs past an
    /// edge (detectors return these) is cut at the edge; an empty or non-finite one gives x0 == x1.
    public func pixelBounds(width w: Int, height h: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        guard x.isFinite && y.isFinite && width.isFinite && height.isFinite else { return (0, 0, 0, 0) }
        func clamp(_ v: Double, _ limit: Int) -> Int { Int(min(max(v, 0), Double(limit))) }
        let x0 = clamp(floor(x * Double(w)), w), y0 = clamp(floor(y * Double(h)), h)
        let x1 = max(x0, clamp(ceil((x + width) * Double(w)), w))
        let y1 = max(y0, clamp(ceil((y + height) * Double(h)), h))
        return (x0, y0, x1, y1)
    }
}
enum PNGCodec {
    static func encode(width: Int, height: Int, bytes: [UInt8], gray: Bool) -> Data {
        let data = Data(bytes)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let bits = gray ? CGBitmapInfo(rawValue: 0) : CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: gray ? 8 : 32, bytesPerRow: width * (gray ? 1 : 4),
                            space: space, bitmapInfo: bits, provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "PNG encoding failed")
        return output as Data
    }
}
