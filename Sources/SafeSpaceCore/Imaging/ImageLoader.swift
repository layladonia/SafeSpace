import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct WorkingCopy: Sendable {
    public let image: SRGBImage
    public let provenance: ImageProvenance
}
public enum ImageLoader {
    public static func load(url: URL, maxLongSide: Int = 1024) throws -> WorkingCopy {
        try load(data: Data(contentsOf: url), source: .file, maxLongSide: maxLongSide)
    }
    public static func load(data: Data, source: ImageSource, maxLongSide: Int = 1024) throws -> WorkingCopy {
        try Task.checkCancellation()
        guard maxLongSide > 0, !data.isEmpty,
              let input = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw SafeSpaceError.load(.unreadableData) }
        let w = image.width, h = image.height
        guard w > 0 && h > 0 && w <= 100_000_000 / h else { throw SafeSpaceError.load(.emptyImage) }
        let props = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation), let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SafeSpaceError.load(.unsupportedColorSpace)
        }
        let format: String
        let type = (CGImageSourceGetType(input) as String?) ?? ""
        if let ut = UTType(type), ut.conforms(to: .heic) || ut.identifier == "public.heif" { format = "heic" }
        else if type == UTType.jpeg.identifier { format = "jpeg" }
        else if type == UTType.png.identifier { format = "png" }
        else { format = "other" }
        let profileName = (image.colorSpace?.name as String?) ?? ""
        let hasProfile = props[kCGImagePropertyProfileName] != nil
        let profile: String
        if !hasProfile && profileName.isEmpty { profile = "untagged" }
        else if profileName.localizedCaseInsensitiveContains("p3") { profile = "display_p3" }
        else if profileName.localizedCaseInsensitiveContains("srgb") { profile = "srgb" }
        else { profile = hasProfile ? "other" : "untagged" }

        // Color-manage into full-resolution gamma-encoded sRGB, then perform our
        // explicitly recorded bilinear resize. This avoids a hidden ImageIO resize kernel.
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = raw.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
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
        let swapped = (5...8).contains(orientation)
        let uprightW = swapped ? h : w, uprightH = swapped ? w : h
        let scale = min(1, Double(maxLongSide) / Double(max(uprightW, uprightH)))
        let outW = max(1, Int(Double(uprightW) * scale))
        let outH = max(1, Int(Double(uprightH) * scale))
        var output = [UInt8](repeating: 0, count: outW * outH * 4)
        func sourceOffset(_ x: Int, _ y: Int) -> Int {
            let sx: Int, sy: Int
            switch orientation {
            case 2: sx = w - 1 - x; sy = y
            case 3: sx = w - 1 - x; sy = h - 1 - y
            case 4: sx = x; sy = h - 1 - y
            case 5: sx = y; sy = x
            case 6: sx = y; sy = h - 1 - x
            case 7: sx = w - 1 - y; sy = h - 1 - x
            case 8: sx = w - 1 - y; sy = x
            default: sx = x; sy = y
            }
            return (sy * w + sx) * 4
        }
        for y in 0..<outH {
            if y % 32 == 0 { try Task.checkCancellation() }
            let fy = Double(y) * Double(uprightH - 1) / Double(max(outH - 1, 1))
            let y0 = Int(fy), y1 = min(y0 + 1, uprightH - 1), dy = fy - Double(y0)
            for x in 0..<outW {
                let fx = Double(x) * Double(uprightW - 1) / Double(max(outW - 1, 1))
                let x0 = Int(fx), x1 = min(x0 + 1, uprightW - 1), dx = fx - Double(x0)
                let p00 = sourceOffset(x0, y0), p10 = sourceOffset(x1, y0)
                let p01 = sourceOffset(x0, y1), p11 = sourceOffset(x1, y1)
                for c in 0..<4 {
                    let top = Double(raw[p00 + c]) * (1 - dx) + Double(raw[p10 + c]) * dx
                    let bottom = Double(raw[p01 + c]) * (1 - dx) + Double(raw[p11 + c]) * dx
                    output[(y * outW + x) * 4 + c] = UInt8(min(255, max(0, (top * (1 - dy) + bottom * dy).rounded())))
                }
            }
        }
        return WorkingCopy(image: .init(width: outW, height: outH, rgba: output), provenance: .init(
            source: source,
            original: .init(format: format, colorSpace: profile, width: w, height: h,
                            exifOrientation: orientation, retained: source == .file),
            workingCopy: .init(colorSpace: "srgb", width: outW, height: outH, maxLongSide: maxLongSide,
                               resizeMethod: "bilinear_gamma_encoded", orientationApplied: true, gamutMapping: "clip")))
    }
}
