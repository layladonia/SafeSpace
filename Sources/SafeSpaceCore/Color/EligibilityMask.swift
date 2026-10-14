
// Placeholder for pplying optional masks to pixel data
// Uses Pixels to represent an image as raw pixel data using uses RGBA8 (red, green, blue, alpha (opacity))
public struct EligibilityMask {
    public static func apply(mask: Pixels?, to image: Pixels) -> Pixels {
        guard mask != nil else { return image }
        // Mask filtering logic here
        return image
    }
}
