import Foundation

public struct ImagePipeline {
    public static func analyze(imageURL: URL, mask: PixelBuffer? = nil) -> ([PerceptualColor], [PerceptualColor])? {
        guard let normalizedImage = ImageToSRGB.processImage(at: imageURL) else { return nil }

        let maskedImage = EligibilityMask.apply(mask: mask, to: normalizedImage)
        guard maskedImage.width > 0, maskedImage.height > 0 else { return nil }

        var perceptualColorsOKLab: [PerceptualColor] = []
        var perceptualColorsCIELAB: [PerceptualColor] = []

        for y in 0..<maskedImage.height {
            for x in 0..<maskedImage.width {
                let offset = (y * maskedImage.width + x) * 4
                let alpha = Double(maskedImage.bytes[offset + 3]) / 255.0

                guard alpha > 0.0 else { continue }

                let r = Double(maskedImage.bytes[offset + 0]) / 255.0
                let g = Double(maskedImage.bytes[offset + 1]) / 255.0
                let b = Double(maskedImage.bytes[offset + 2]) / 255.0

                perceptualColorsOKLab.append(ColorSpace.sRGBToOKLab(r: r, g: g, b: b))

                perceptualColorsCIELAB.append(ColorSpace.sRGBToCIELAB(r: r, g: g, b: b))
            }
        }

        return (perceptualColorsOKLab, perceptualColorsCIELAB)
    }
}
