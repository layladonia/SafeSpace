import Foundation

// Compatibility adapter for existing callers. New callers use ImageLoader.
public struct ImageToSRGB {
    public static func processImage(at url: URL) -> Pixels? {
        guard let image = try? ImageLoader.load(url: url).image else { return nil }
        return Pixels(width: image.width, height: image.height, bytes: image.rgba)
    }
}
