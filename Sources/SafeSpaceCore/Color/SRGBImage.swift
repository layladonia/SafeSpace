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
    public func pixelBounds(width w: Int, height h: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        precondition(x.isFinite && y.isFinite && width.isFinite && height.isFinite)
        precondition(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1)
        return (Int(floor(x * Double(w))), Int(floor(y * Double(h))),
                min(w, Int(ceil((x + width) * Double(w)))), min(h, Int(ceil((y + height) * Double(h)))))
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
