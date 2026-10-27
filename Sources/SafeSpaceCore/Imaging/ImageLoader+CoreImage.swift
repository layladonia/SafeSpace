#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import ImageIO
import Foundation

extension ImageLoader {
    /// Decodes to straight-alpha RGBA8 in the image's own embedded color space — no sRGB
    /// conversion here, that's shared with the stb path once we have ICC bytes. CIContext's
    /// explicit `.RGBA8` format and `unpremultiplyingAlpha()` are used because a CGImage's raw
    /// byte layout/premultiplication is undocumented and varies by source format (HEIC vs JPEG
    /// vs PNG); these are the only APIs that guarantee it. No orientation is applied either —
    /// the shared `process` does that from the raw EXIF tag, same as the stb path.
    static func decodeViaCoreImage(_ data: Data) throws -> RawDecode {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw SafeSpaceError.load(.unreadableData)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int
        let iccProfile = (cgImage.colorSpace?.copyICCData() as Data?).map { [UInt8]($0) }

        let straight = CIImage(cgImage: cgImage).unpremultiplyingAlpha()
        let space = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let normalized = CIContext().createCGImage(straight, from: straight.extent, format: .RGBA8, colorSpace: space) else {
            throw SafeSpaceError.load(.unreadableData)
        }
        try validateDimensions(width: normalized.width, height: normalized.height)
        let raw = try rgba8Bytes(from: normalized, width: normalized.width, height: normalized.height)
        return RawDecode(raw: raw, width: normalized.width, height: normalized.height,
                          orientation: orientation, iccProfile: iccProfile)
    }
}

/// Copies RGBA8 bytes out of `cgImage` into a tightly packed `width * height * 4` buffer,
/// stripping whatever row padding CoreGraphics applied to `bytesPerRow`.
private func rgba8Bytes(from cgImage: CGImage, width: Int, height: Int) throws -> [UInt8] {
    guard let cfData = cgImage.dataProvider?.data, let srcPtr = CFDataGetBytePtr(cfData) else {
        throw SafeSpaceError.load(.unreadableData)
    }
    let bytesPerRow = cgImage.bytesPerRow
    guard bytesPerRow >= width * 4, CFDataGetLength(cfData) >= bytesPerRow * height else {
        throw SafeSpaceError.load(.unreadableData)
    }
    var output = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        let destStart = y * width * 4
        for i in 0..<(width * 4) {
            output[destStart + i] = srcPtr[rowStart + i]
        }
    }
    return output
}
#endif
