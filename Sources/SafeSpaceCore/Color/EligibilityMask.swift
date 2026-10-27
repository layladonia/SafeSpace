import Foundation
import CStbImage

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
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        guard let decoded = pngData.withUnsafeBytes({ rawBuffer -> UnsafeMutablePointer<UInt8>? in
            stbi_load_from_memory(rawBuffer.bindMemory(to: UInt8.self).baseAddress, Int32(pngData.count),
                                   &width, &height, &channels, 1)
        }) else { throw SafeSpaceError.load(.unreadableData) }
        defer { stbi_image_free(decoded) }
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0 else { throw SafeSpaceError.load(.unreadableData) }
        let bytes = Array(UnsafeBufferPointer(start: decoded, count: w * h))
        self.init(width: w, height: h, eligible: bytes.map { $0 >= 128 })
    }
}
