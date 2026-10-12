// Decodes images into sRGB and downsizes to a 1024px max dimension.
// converts from Display P3-tagged JPEGs to sRGB if necessary

import CStbImage
import Foundation

public struct ImageToSRGB {
    public static func processImage(at url: URL) -> PixelBuffer? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var width: Int32 = 0
        var height: Int32 = 0
        var channels: Int32 = 0
        guard let decoded = data.withUnsafeBytes({ rawBuffer -> UnsafeMutablePointer<UInt8>? in
            stbi_load_from_memory(
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                Int32(data.count),
                &width,
                &height,
                &channels,
                4
                )
        }) else { return nil }

        // frees the memory used to store the decoded image when the function finishes running
        defer { stbi_image_free(decoded) }

        let bytes = Array(UnsafeBufferPointer(start: decoded, count: Int(width) * Int(height) * 4))
        let image = PixelBuffer(width: Int(width), height: Int(height), bytes: bytes)
        let profile = colorProfile(of: data)

        // if it's not sRGB or p3, we can't analyze it right now
        guard profile != .unsupported else { return nil }

        let maxDimension = max(image.width, image.height)
        var resized = image
        if maxDimension > 1024 {
            let scale = 1024.0 / Double(maxDimension)
            let targetWidth = max(Int(Double(image.width) * scale), 1)
            let targetHeight = max(Int(Double(image.height) * scale), 1)
            resized = bilinearResize(image, to: targetWidth, targetHeight)
        }

        return profile == .displayP3 ? convertDisplayP3ToSRGB(resized) : resized
    }

    private enum ColorProfile: Equatable {
        case none      
        case sRGB
        case displayP3
        case unsupported
    }

    private static func colorProfile(of data: Data) -> ColorProfile {
        guard let profile = extractICCProfile(from: data) else { return .none }
        if contains(profile, Array("Display P3".utf8)) { return .displayP3 }
        if contains(profile, Array("sRGB".utf8)) { return .sRGB }
        return .unsupported
    }

    // converting iphone images to sRGB
    private static func convertDisplayP3ToSRGB(_ buffer: PixelBuffer) -> PixelBuffer {
        var bytes = buffer.bytes
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let converted = ColorSpace.displayP3ToSRGB(
                r: Double(bytes[offset]) / 255.0,
                g: Double(bytes[offset + 1]) / 255.0,
                b: Double(bytes[offset + 2]) / 255.0
            )
            bytes[offset] = UInt8((converted.r * 255.0).rounded())
            bytes[offset + 1] = UInt8((converted.g * 255.0).rounded())
            bytes[offset + 2] = UInt8((converted.b * 255.0).rounded())
        }
        return PixelBuffer(width: buffer.width, height: buffer.height, bytes: bytes)
    }


    /// Extracts a JPEG's embedded ICC profile bytes from its APP2 `ICC_PROFILE` segments
    /// (uncompressed per spec, possibly split across multiple segments). Returns nil for
    /// non-JPEG data or JPEGs with no embedded profile.
    private static func extractICCProfile(from data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var offset = 2
        var chunks: [Int: [UInt8]] = [:]
        let iccHeader = Array("ICC_PROFILE\0".utf8)

        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
                offset += 2
                if marker == 0xD9 { break }
                continue
            }

            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { break }
            let segmentStart = offset + 4
            let segmentEnd = offset + 2 + length

            if marker == 0xE2, segmentEnd - segmentStart > iccHeader.count + 2,
               Array(bytes[segmentStart..<(segmentStart + iccHeader.count)]) == iccHeader {
                let sequence = Int(bytes[segmentStart + iccHeader.count])
                chunks[sequence] = Array(bytes[(segmentStart + iccHeader.count + 2)..<segmentEnd])
            }

            if marker == 0xDA { break }
            offset = segmentEnd
        }

        guard !chunks.isEmpty else { return nil }
        return chunks.keys.sorted().flatMap { chunks[$0]! }
    }

    private static func contains(_ source: [UInt8], _ target: [UInt8]) -> Bool {
        guard !target.isEmpty, source.count >= target.count else { return false }
        for i in 0...(source.count - target.count) {
            if Array(source[i..<(i + target.count)]) == target { return true }
        }
        return false
    }

    // calculates a new pixel's color from the four nearest pixels
    private static func bilinearResize(_ src: PixelBuffer, to targetWidth: Int, _ targetHeight: Int) -> PixelBuffer {
        var dst = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let xRatio = Double(src.width - 1) / Double(max(targetWidth - 1, 1))
        let yRatio = Double(src.height - 1) / Double(max(targetHeight - 1, 1))

        for dy in 0..<targetHeight {
            let srcY = Double(dy) * yRatio
            let y0 = Int(srcY)
            let y1 = min(y0 + 1, src.height - 1)
            let yFrac = srcY - Double(y0)

            for dx in 0..<targetWidth {
                let srcX = Double(dx) * xRatio
                let x0 = Int(srcX)
                let x1 = min(x0 + 1, src.width - 1)
                let xFrac = srcX - Double(x0)

                let dstOffset = (dy * targetWidth + dx) * 4
                for c in 0..<4 {
                    let p00 = Double(src.bytes[(y0 * src.width + x0) * 4 + c])
                    let p10 = Double(src.bytes[(y0 * src.width + x1) * 4 + c])
                    let p01 = Double(src.bytes[(y1 * src.width + x0) * 4 + c])
                    let p11 = Double(src.bytes[(y1 * src.width + x1) * 4 + c])
                    let top = p00 + (p10 - p00) * xFrac
                    let bottom = p01 + (p11 - p01) * xFrac
                    dst[dstOffset + c] = UInt8((top + (bottom - top) * yFrac).rounded())
                }
            }
        }
        return PixelBuffer(width: targetWidth, height: targetHeight, bytes: dst)
    }
}