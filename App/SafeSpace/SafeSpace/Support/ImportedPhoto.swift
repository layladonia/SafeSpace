import ImageIO
import UIKit
import UniformTypeIdentifiers

enum PhotoImportError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        "The file isn't an image the app can read."
    }
}

/// Where a photo came from. Recorded so results can say which input produced them.
enum PhotoSource: String {
    case library, camera
}

/// One photo picked or taken by the user.
///
/// `originalData` is kept byte-for-byte as Photos delivered it (HEIC, JPEG, PNG),
/// including its embedded color profile (usually Display P3 on iPhone). The sRGB
/// working copy and color conversions are Task 3's job in SafeSpaceCore; the shell
/// never alters these bytes. Everything is held in memory only.
///
/// Camera photos are different: the system camera screen returns a processed
/// image, not a file, so `CameraPicker` re-encodes it as an upright JPEG.
struct ImportedPhoto: Identifiable {
    let id = UUID()
    let originalData: Data
    let contentType: UTType?
    let source: PhotoSource
    /// Stored pixel size, before EXIF orientation is applied.
    let pixelWidth: Int
    let pixelHeight: Int
    /// EXIF orientation 1–8 (1 = upright). Recorded for the data manifest.
    let exifOrientation: Int
    /// Downsampled, orientation-corrected image for display only. Not for analysis.
    let preview: UIImage

    init(
        data: Data,
        contentType: UTType?,
        source: PhotoSource = .library,
        previewMaxPixelSize: Int = 2048
    ) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw PhotoImportError.unreadableImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]

        // Decoding a full 12–48 MP photo just to show it would waste memory,
        // so ImageIO creates a bounded thumbnail with orientation applied.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, thumbnailOptions as CFDictionary
        ) else {
            throw PhotoImportError.unreadableImage
        }

        self.originalData = data
        self.contentType = contentType
        self.source = source
        self.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? thumbnail.width
        self.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? thumbnail.height
        self.exifOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        self.preview = UIImage(cgImage: thumbnail)
    }

    /// Width × height as the user sees the photo (orientations 5–8 are rotated 90°).
    var displayedSize: (width: Int, height: Int) {
        (5...8).contains(exifOrientation)
            ? (pixelHeight, pixelWidth)
            : (pixelWidth, pixelHeight)
    }

    var formatName: String {
        contentType?.preferredFilenameExtension?.uppercased() ?? "Image"
    }

    /// e.g. "4032 × 3024 pixels, HEIC, from library"
    var summary: String {
        "\(displayedSize.width) × \(displayedSize.height) pixels, \(formatName), from \(source.rawValue)"
    }
}
