#if canImport(CoreImage)
import CoreGraphics
import ImageIO
import Foundation

extension ImageLoader {
    /// Decodes and color-manages into straight-alpha RGBA8 sRGB, the same way the old
    /// CoreGraphics-only loader on main did: draw into a CGContext targeting an explicit sRGB
    /// destination so CoreGraphics' own CMM performs the embedded-profile conversion, then
    /// unpremultiply manually. `alreadySRGB` tells the shared `process` to skip its hand-rolled
    /// ICC matrix conversion, since there's nothing left for it to do on this backend.
    static func decodeViaCoreImage(_ data: Data) throws -> RawDecode {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw SafeSpaceError.load(.unreadableData) }
        let w = cgImage.width, h = cgImage.height
        try validateDimensions(width: w, height: h)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let iccProfile = (cgImage.colorSpace?.copyICCData() as Data?).map { [UInt8]($0) }

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SafeSpaceError.load(.unsupportedColorSpace)
        }
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = raw.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard rendered else { throw SafeSpaceError.load(.unreadableData) }
        // Straight alpha. Alpha never decides eligibility. Zero-alpha RGB is zero.
        for p in stride(from: 0, to: raw.count, by: 4) {
            let alpha = Int(raw[p + 3])
            for c in 0..<3 {
                raw[p + c] = alpha == 0 ? 0 : UInt8(min(255, (Int(raw[p + c]) * 255 + alpha / 2) / alpha))
            }
        }
        return RawDecode(raw: raw, width: w, height: h, orientation: orientation,
                          iccProfile: iccProfile, alreadySRGB: true)
    }
}
#endif
