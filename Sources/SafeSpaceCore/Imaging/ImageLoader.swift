import Foundation
#if !canImport(CoreImage)
import CStbImage
#endif

public struct WorkingCopy: Sendable {
    public let image: SRGBImage
    public let provenance: ImageProvenance
}
public enum ImageLoader {
    /// Raw, un-oriented, un-color-matched RGBA8 pixels plus the metadata needed to finish the
    /// job — produced by whichever backend decoded the bytes, then handed to the one shared
    /// `process` below so orientation/color/resize logic isn't duplicated per backend.
    struct RawDecode {
        var raw: [UInt8]
        var width: Int
        var height: Int
        var orientation: Int?
        var iccProfile: [UInt8]?
        /// True when the backend already color-managed `raw` into sRGB itself (e.g. by letting
        /// CoreGraphics' CMM do the conversion at decode time), so `process` should skip its
        /// own ICC-matrix conversion/rejection below.
        var alreadySRGB: Bool = false
    }

    /// EXIF orientation to apply. Missing or out-of-range values (0 is common) mean "not set",
    /// which EXIF defines as upright.
    static func uprightOrientation(_ tagged: Int?) -> Int {
        guard let tagged, (1...8).contains(tagged) else { return 1 }
        return tagged
    }
    static func resizedDimensions(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxLongSide) / Double(max(width, height)))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }
    /// Rejects degenerate or pixel-count-overflow-prone dimensions before any backend allocates
    /// a buffer sized from them.
    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 100_000_000 / height else { throw SafeSpaceError.load(.emptyImage) }
    }

    public static func load(url: URL, maxLongSide: Int = 1024) throws -> WorkingCopy {
        try load(data: Data(contentsOf: url), source: .file, maxLongSide: maxLongSide)
    }
    public static func load(data: Data, source: ImageSource, maxLongSide: Int = 1024) throws -> WorkingCopy {
        try Task.checkCancellation()
        guard maxLongSide > 0, !data.isEmpty else { throw SafeSpaceError.load(.emptyImage) }
        let format = sniffFormat(data)
        #if canImport(CoreImage)
        let decoded = try decodeViaCoreImage(data)
        #else
        let decoded = try decodeViaSTB(data)
        #endif
        return try process(decoded, format: format, source: source, maxLongSide: maxLongSide)
    }

    #if !canImport(CoreImage)
    private static func decodeViaSTB(_ data: Data) throws -> RawDecode {
        let metadata = sniffFormat(data) == "jpeg" ? scanJPEGMetadata(data) : JPEGMetadata(orientation: nil, iccProfile: nil)
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        guard let decoded = data.withUnsafeBytes({ rawBuffer -> UnsafeMutablePointer<UInt8>? in
            stbi_load_from_memory(rawBuffer.bindMemory(to: UInt8.self).baseAddress, Int32(data.count),
                                   &width, &height, &channels, 4)
        }) else { throw SafeSpaceError.load(.unreadableData) }
        defer { stbi_image_free(decoded) }
        let w = Int(width), h = Int(height)
        try validateDimensions(width: w, height: h)
        // stb_image returns straight (non-premultiplied) alpha for both PNG and JPEG
        // (JPEG has no alpha channel; stb_image fills it opaque).
        let raw = Array(UnsafeBufferPointer(start: decoded, count: w * h * 4))
        return RawDecode(raw: raw, width: w, height: h, orientation: metadata.orientation,
                          iccProfile: metadata.iccProfile, alreadySRGB: false)
    }
    #endif

    /// Shared by every backend: ICC color-matching, EXIF orientation, and the area-average
    /// resize, applied identically regardless of which decoder produced the raw pixels.
    private static func process(_ decoded: RawDecode, format: String, source: ImageSource, maxLongSide: Int) throws -> WorkingCopy {
        let w = decoded.width, h = decoded.height
        var raw = decoded.raw
        let orientation = uprightOrientation(decoded.orientation)
        let profile = colorProfile(iccProfile: decoded.iccProfile)
        // CoreImage's backend already color-manages into sRGB itself via CoreGraphics' CMM at
        // decode time (ImageLoader+CoreImage.swift), so `profile` below is provenance labeling
        // only on that path. Only a backend without a system CMM (stb) needs this hand-rolled
        // ICC-matrix conversion/rejection to happen here.
        if !decoded.alreadySRGB {
            switch profile {
            case .displayP3:
                for p in stride(from: 0, to: raw.count, by: 4) {
                    let converted = ColorSpace.displayP3ToSRGB(r: Double(raw[p]) / 255.0,
                                                                g: Double(raw[p + 1]) / 255.0,
                                                                b: Double(raw[p + 2]) / 255.0)
                    raw[p] = UInt8((converted.r * 255.0).rounded())
                    raw[p + 1] = UInt8((converted.g * 255.0).rounded())
                    raw[p + 2] = UInt8((converted.b * 255.0).rounded())
                }
            case .adobeRGB:
                for p in stride(from: 0, to: raw.count, by: 4) {
                    let converted = ColorSpace.adobeRGBToSRGB(r: Double(raw[p]) / 255.0,
                                                               g: Double(raw[p + 1]) / 255.0,
                                                               b: Double(raw[p + 2]) / 255.0)
                    raw[p] = UInt8((converted.r * 255.0).rounded())
                    raw[p + 1] = UInt8((converted.g * 255.0).rounded())
                    raw[p + 2] = UInt8((converted.b * 255.0).rounded())
                }
            case .other:
                // No ICC engine here: a tagged profile we can't identify as sRGB, Display P3, or
                // Adobe RGB would be silently misinterpreted, so refuse to analyze it rather than guess.
                throw SafeSpaceError.load(.unsupportedColorSpace)
            case .srgb, .untagged:
                break
            }
        }

        let swapped = (5...8).contains(orientation)
        let uprightW = swapped ? h : w, uprightH = swapped ? w : h
        let (outW, outH) = resizedDimensions(width: uprightW, height: uprightH, maxLongSide: maxLongSide)
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
        // Each output pixel is the mean of every upright source pixel its footprint covers,
        // so a large shrink uses the whole photo instead of sampling points. Integer sums keep
        // it exact and deterministic; without a resize each footprint is a single pixel.
        for y in 0..<outH {
            if y % 32 == 0 { try Task.checkCancellation() }
            let sy0 = y * uprightH / outH, sy1 = max(sy0 + 1, (y + 1) * uprightH / outH)
            for x in 0..<outW {
                let sx0 = x * uprightW / outW, sx1 = max(sx0 + 1, (x + 1) * uprightW / outW)
                var sums = (0, 0, 0, 0)
                for sy in sy0..<sy1 {
                    for sx in sx0..<sx1 {
                        let p = sourceOffset(sx, sy)
                        sums.0 += Int(raw[p]); sums.1 += Int(raw[p + 1])
                        sums.2 += Int(raw[p + 2]); sums.3 += Int(raw[p + 3])
                    }
                }
                let n = (sy1 - sy0) * (sx1 - sx0), o = (y * outW + x) * 4
                output[o] = UInt8((sums.0 + n / 2) / n); output[o + 1] = UInt8((sums.1 + n / 2) / n)
                output[o + 2] = UInt8((sums.2 + n / 2) / n); output[o + 3] = UInt8((sums.3 + n / 2) / n)
            }
        }
        return WorkingCopy(image: .init(width: outW, height: outH, rgba: output), provenance: .init(
            source: source,
            original: .init(format: format, colorSpace: profile.rawValue, width: w, height: h,
                            exifOrientation: orientation, retained: source == .file),
            workingCopy: .init(colorSpace: "srgb", width: outW, height: outH, maxLongSide: maxLongSide,
                               resizeMethod: "area_average_gamma_encoded", orientationApplied: true, gamutMapping: "clip")))
    }
}

/// Magic-byte sniff; neither backend's decoder reports a source format on its own.
func sniffFormat(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(12))
    guard bytes.count >= 4 else { return "other" }
    if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpeg" }
    if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
    if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
        let brand = String(decoding: bytes[8..<12], as: UTF8.self)
        if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "heic" }
    }
    return "other"
}

#if !canImport(CoreImage)
private struct JPEGMetadata {
    var orientation: Int?
    var iccProfile: [UInt8]?
}

/// Scans JPEG markers for the APP1 Exif orientation tag and APP2 ICC_PROFILE segments
/// (uncompressed per spec, possibly split across multiple segments) without a full EXIF/ICC
/// library — stb_image decodes pixels only and reports neither.
private func scanJPEGMetadata(_ data: Data) -> JPEGMetadata {
    let bytes = [UInt8](data)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return JPEGMetadata(orientation: nil, iccProfile: nil) }

    let exifHeader = Array("Exif\0\0".utf8)
    let iccHeader = Array("ICC_PROFILE\0".utf8)
    var offset = 2
    var orientation: Int?
    var iccChunks: [Int: [UInt8]] = [:]

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

        if orientation == nil, marker == 0xE1, segmentEnd - segmentStart > exifHeader.count,
           Array(bytes[segmentStart..<(segmentStart + exifHeader.count)]) == exifHeader {
            orientation = parseEXIFOrientation(bytes, tiffStart: segmentStart + exifHeader.count, segmentEnd: segmentEnd)
        }
        if marker == 0xE2, segmentEnd - segmentStart > iccHeader.count + 2,
           Array(bytes[segmentStart..<(segmentStart + iccHeader.count)]) == iccHeader {
            let sequence = Int(bytes[segmentStart + iccHeader.count])
            iccChunks[sequence] = Array(bytes[(segmentStart + iccHeader.count + 2)..<segmentEnd])
        }
        if marker == 0xDA { break }
        offset = segmentEnd
    }
    let icc = iccChunks.isEmpty ? nil : iccChunks.keys.sorted().flatMap { iccChunks[$0]! }
    return JPEGMetadata(orientation: orientation, iccProfile: icc)
}

/// Reads the IFD0 Orientation tag (0x0112) out of a TIFF structure embedded in an Exif segment.
private func parseEXIFOrientation(_ bytes: [UInt8], tiffStart: Int, segmentEnd: Int) -> Int? {
    guard tiffStart + 8 <= segmentEnd, tiffStart + 8 <= bytes.count else { return nil }
    let little: Bool
    if bytes[tiffStart] == 0x49, bytes[tiffStart + 1] == 0x49 { little = true }
    else if bytes[tiffStart] == 0x4D, bytes[tiffStart + 1] == 0x4D { little = false }
    else { return nil }
    func u16(_ at: Int) -> Int {
        little ? Int(bytes[at]) | (Int(bytes[at + 1]) << 8) : (Int(bytes[at]) << 8) | Int(bytes[at + 1])
    }
    func u32(_ at: Int) -> Int {
        little ? Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16) | (Int(bytes[at + 3]) << 24)
               : (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16) | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
    }
    let ifdOffset = tiffStart + u32(tiffStart + 4)
    guard ifdOffset + 2 <= segmentEnd, ifdOffset + 2 <= bytes.count else { return nil }
    let entryCount = u16(ifdOffset)
    for i in 0..<entryCount {
        let entryStart = ifdOffset + 2 + i * 12
        guard entryStart + 12 <= segmentEnd, entryStart + 12 <= bytes.count else { break }
        if u16(entryStart) == 0x0112 { return u16(entryStart + 8) }
    }
    return nil
}
#endif

private enum DetectedColorProfile: String {
    case untagged, srgb, displayP3 = "display_p3", adobeRGB = "adobe_rgb", other
}

private func colorProfile(iccProfile: [UInt8]?) -> DetectedColorProfile {
    guard let iccProfile else { return .untagged }

    // Authoritative: compare the profile's actual rXYZ/gXYZ/bXYZ colorimetry against known
    // reference matrices. Profile *names* are often opaque or misleading (e.g. "c2" or
    // "Camera RGB Profile" for an otherwise bog-standard sRGB profile), but the numeric
    // primaries can't lie. Checked against both the ICC-standard D50 PCS-adapted encoding and
    // the native D65 encoding some tools (e.g. scanner/device profiles) use unadapted.
    if let matrix = iccPrimariesMatrix(iccProfile) {
        let tolerance = 0.005
        if matchesReference(matrix, srgbD50, tolerance) || matchesReference(matrix, srgbD65, tolerance) {
            return .srgb
        }
        if matchesReference(matrix, displayP3D50, tolerance) || matchesReference(matrix, displayP3D65, tolerance) {
            return .displayP3
        }
        if matchesReference(matrix, adobeRGBD50, tolerance) || matchesReference(matrix, adobeRGBD65, tolerance) {
            return .adobeRGB
        }
        return .other
    }

    // Fallback when colorimetry tags are missing/unparseable: the human-readable description
    // is a weaker signal (it can be absent or opaque) but better than refusing outright.
    guard let description = iccProfileDescription(iccProfile)?.lowercased() else { return .other }
    if description.contains("display p3") { return .displayP3 }
    if description.contains("adobe rgb") { return .adobeRGB }
    if description.contains("srgb") { return .srgb }
    return .other
}

/// Reads the rXYZ/gXYZ/bXYZ tags (each an XYZType: type(4) + reserved(4) + s15Fixed16 X,Y,Z)
/// and assembles them into the profile's actual RGB->XYZ matrix, column-major by channel.
private func iccPrimariesMatrix(_ icc: [UInt8]) -> [[Double]]? {
    guard icc.count >= 132 else { return nil }
    func u32(_ at: Int) -> Int {
        guard at >= 0, at + 4 <= icc.count else { return 0 }
        return (Int(icc[at]) << 24) | (Int(icc[at + 1]) << 16) | (Int(icc[at + 2]) << 8) | Int(icc[at + 3])
    }
    func s15Fixed16(_ at: Int) -> Double {
        guard at >= 0, at + 4 <= icc.count else { return 0 }
        return Double(Int32(truncatingIfNeeded: u32(at))) / 65536.0
    }
    func readXYZTag(_ signature: String) -> [Double]? {
        let sig = Array(signature.utf8)
        let tagCount = u32(128)
        guard tagCount > 0, tagCount < 1000 else { return nil }
        for i in 0..<tagCount {
            let entryStart = 132 + i * 12
            guard entryStart + 12 <= icc.count, Array(icc[entryStart..<(entryStart + 4)]) == sig else { continue }
            let tagOffset = u32(entryStart + 4)
            let tagSize = u32(entryStart + 8)
            guard tagSize >= 20, tagOffset >= 0, tagOffset + tagSize <= icc.count else { return nil }
            return [s15Fixed16(tagOffset + 8), s15Fixed16(tagOffset + 12), s15Fixed16(tagOffset + 16)]
        }
        return nil
    }
    guard let r = readXYZTag("rXYZ"), let g = readXYZTag("gXYZ"), let b = readXYZTag("bXYZ") else { return nil }
    return [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
}

private func matchesReference(_ matrix: [[Double]], _ reference: [[Double]], _ tolerance: Double) -> Bool {
    for row in 0..<3 {
        for col in 0..<3 {
            if abs(matrix[row][col] - reference[row][col]) > tolerance { return false }
        }
    }
    return true
}

// Reference RGB->XYZ matrices, D65-native and D50-PCS-adapted (Bradford), derived from each
// color space's published chromaticity primaries. Row = X/Y/Z, column = R/G/B.
private let srgbD65: [[Double]] = [[0.41239080, 0.35758434, 0.18048079], [0.21263901, 0.71516868, 0.07219232], [0.01933082, 0.11919478, 0.95053215]]
private let srgbD50: [[Double]] = [[0.43606575, 0.38515151, 0.14307842], [0.22249318, 0.71688701, 0.06061981], [0.01392392, 0.09708132, 0.71409936]]
private let displayP3D65: [[Double]] = [[0.48657095, 0.26566769, 0.19821729], [0.22897456, 0.69173852, 0.07928691], [0.00000000, 0.04511338, 1.04394437]]
private let displayP3D50: [[Double]] = [[0.51514644, 0.29200998, 0.15713925], [0.24120032, 0.69222254, 0.06657714], [-0.00105014, 0.04187827, 0.78427647]]
private let adobeRGBD65: [[Double]] = [[0.57666904, 0.18555824, 0.18822865], [0.29734498, 0.62736357, 0.07529146], [0.02703136, 0.07068885, 0.99133754]]
private let adobeRGBD50: [[Double]] = [[0.60977504, 0.20530000, 0.14922063], [0.31112461, 0.62565323, 0.06322216], [0.01947060, 0.06087909, 0.74475492]]

/// Reads the ICC profile's `desc` tag out of its tag table. Different embedding tools encode
/// this differently per ICC version: Apple ColorSync and littleCMS commonly use the ICC v4
/// `mluc` (multiLocalizedUnicodeType, UTF-16BE) encoding; older tools use the ICC v2 `desc`
/// (TextDescriptionType, ASCII) encoding. A plain byte-level ASCII search misses the former,
/// which is why "Display P3" and "sRGB"-described profiles were going undetected.
private func iccProfileDescription(_ icc: [UInt8]) -> String? {
    guard icc.count >= 132 else { return nil }
    func u32(_ at: Int) -> Int {
        guard at >= 0, at + 4 <= icc.count else { return 0 }
        return (Int(icc[at]) << 24) | (Int(icc[at + 1]) << 16) | (Int(icc[at + 2]) << 8) | Int(icc[at + 3])
    }
    let descTag = Array("desc".utf8)
    let tagCount = u32(128)
    guard tagCount > 0, tagCount < 1000 else { return nil }
    for i in 0..<tagCount {
        let entryStart = 132 + i * 12
        guard entryStart + 12 <= icc.count, Array(icc[entryStart..<(entryStart + 4)]) == descTag else { continue }
        let tagOffset = u32(entryStart + 4)
        let tagSize = u32(entryStart + 8)
        guard tagSize >= 8, tagOffset >= 0, tagOffset + tagSize <= icc.count else { return nil }
        let typeSignature = Array(icc[tagOffset..<(tagOffset + 4)])

        if typeSignature == descTag {
            // TextDescriptionType (ICC v2): type(4) + reserved(4) + asciiCount(4) + ASCII bytes
            let asciiCount = u32(tagOffset + 8)
            let start = tagOffset + 12
            guard asciiCount > 0, start + asciiCount <= icc.count else { return nil }
            return String(decoding: icc[start..<(start + asciiCount - 1)], as: UTF8.self) // drop NUL terminator
        }
        if typeSignature == Array("mluc".utf8) {
            // multiLocalizedUnicodeType (ICC v4): type(4) + reserved(4) + recordCount(4) +
            // recordSize(4), then records of lang(2) + country(2) + length(4) + offset(4),
            // where offset/length point at UTF-16BE text relative to the tag's own start.
            let recordCount = u32(tagOffset + 8)
            guard recordCount > 0 else { return nil }
            let recordStart = tagOffset + 16
            let length = u32(recordStart + 4)
            let stringOffset = tagOffset + u32(recordStart + 8)
            guard length > 0, length % 2 == 0, stringOffset + length <= icc.count else { return nil }
            let codeUnits = stride(from: stringOffset, to: stringOffset + length, by: 2).map {
                UInt16(icc[$0]) << 8 | UInt16(icc[$0 + 1])
            }
            return String(decoding: codeUnits, as: UTF16.self)
        }
        return nil
    }
    return nil
}
