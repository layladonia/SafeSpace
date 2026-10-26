import ImageIO
import UIKit
import UniformTypeIdentifiers

enum PhotoImportError: LocalizedError {
    case unreadableImage
    var errorDescription: String? { "The file isn't an image the app can read." }
}
enum PhotoSource: String { case library, camera }
struct ImportedPhoto: Identifiable {
    let id = UUID()
    private(set) var originalData: Data
    let contentType: UTType?
    let source: PhotoSource
    let pixelWidth: Int
    let pixelHeight: Int
    let exifOrientation: Int
    let preview: UIImage

    init(data: Data, contentType: UTType?, source: PhotoSource = .library,
         previewMaxPixelSize: Int = 2048) throws {
        guard let input = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(input) > 0 else { throw PhotoImportError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: previewMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
            throw PhotoImportError.unreadableImage
        }
        originalData = data; self.contentType = contentType; self.source = source
        pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? thumbnail.width
        pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? thumbnail.height
        exifOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        preview = UIImage(cgImage: thumbnail)
    }
    mutating func discardOriginalData() { originalData = Data() }
    var displayedSize: (width: Int, height: Int) {
        (5...8).contains(exifOrientation) ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
    }
    var formatName: String { contentType?.preferredFilenameExtension?.uppercased() ?? "Image" }
    var summary: String {
        "\(displayedSize.width) × \(displayedSize.height) pixels, \(formatName), from \(source.rawValue)"
    }
}
