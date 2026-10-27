// Converts an sRGB to OKLab or CIELAB
import Foundation

public struct PerceptualColor: Equatable, CustomStringConvertible {
    /// Lightness channel
    public let L: Double
    /// Chromaticity channel a (Green–Red axis in CIELAB/OKLab)
    public let a: Double
    /// Chromaticity channel b (Blue–Yellow axis in CIELAB/OKLab)
    public let b: Double
    
    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    public var description: String {
        return String(format: "L: %.4f, a: %.4f, b: %.4f", L, a, b)
    }
}

public enum ColorSpace {
    public static func sRGBToOKLab(r: Double, g: Double, b: Double) -> PerceptualColor {
        let rL = sRGBToLinear(r)
        let gL = sRGBToLinear(g)
        let bL = sRGBToLinear(b)

        let l = 0.4122214708 * rL + 0.5363325363 * gL + 0.0514459929 * bL
        let m = 0.2119034982 * rL + 0.6806995451 * gL + 0.1073969566 * bL
        let s = 0.0883024619 * rL + 0.2817188376 * gL + 0.6299787005 * bL

        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)

        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bOut = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        
        return PerceptualColor(L: L, a: a, b: bOut)
    }

    public static func sRGBToCIELAB(r: Double, g: Double, b: Double) -> PerceptualColor {
        let rL = sRGBToLinear(r)
        let gL = sRGBToLinear(g)
        let bL = sRGBToLinear(b)

        var X = rL * 0.4124564 + gL * 0.3575761 + bL * 0.1804375
        var Y = rL * 0.2126729 + gL * 0.7151522 + bL * 0.0721750
        var Z = rL * 0.0193339 + gL * 0.1191920 + bL * 0.9503041

        X /= 0.95047
        Y /= 1.00000
        Z /= 1.08883

        let fX = labPivot(X)
        let fY = labPivot(Y)
        let fZ = labPivot(Z)
        
        let L = max(0.0, 116.0 * fY - 16.0)
        let a = 500.0 * (fX - fY)
        let bOut = 200.0 * (fY - fZ)
        
        return PerceptualColor(L: L, a: a, b: bOut)
    }

    /// For iPhone / iPad photos
    public static func displayP3ToSRGB(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let rL = sRGBToLinear(r)
        let gL = sRGBToLinear(g)
        let bL = sRGBToLinear(b)

        let rOut = 1.2249401762 * rL - 0.2249404758 * gL + 0.0000000000 * bL
        let gOut = -0.0420569547 * rL + 1.0420571330 * gL + 0.0000000000 * bL
        let bOut = -0.0196375546 * rL - 0.0786360454 * gL + 1.0982735000 * bL

        return (
            r: linearToSRGB(min(max(rOut, 0.0), 1.0)),
            g: linearToSRGB(min(max(gOut, 0.0), 1.0)),
            b: linearToSRGB(min(max(bOut, 0.0), 1.0))
        )
    }

    /// For photos tagged with the Adobe RGB (1998) working-space profile (common out of
    /// desktop photo editors). Adobe RGB uses a pure 2.19921875 gamma, not the sRGB piecewise
    /// curve, so its linearization differs from `displayP3ToSRGB`'s.
    public static func adobeRGBToSRGB(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let gamma = 2.19921875
        let rL = pow(max(r, 0), gamma)
        let gL = pow(max(g, 0), gamma)
        let bL = pow(max(b, 0), gamma)

        let rOut = 1.398355744 * rL - 0.398355744 * gL + 0.0 * bL
        let gOut = 0.0 * rL + 1.0 * gL + 0.0 * bL
        let bOut = 0.0 * rL - 0.0429289893 * gL + 1.0429289893 * bL

        return (
            r: linearToSRGB(min(max(rOut, 0.0), 1.0)),
            g: linearToSRGB(min(max(gOut, 0.0), 1.0)),
            b: linearToSRGB(min(max(bOut, 0.0), 1.0))
        )
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        if value <= 0.04045 {
            return value / 12.92
        } else {
            return pow((value + 0.055) / 1.055, 2.4)
        }
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        if value <= 0.0031308 {
            return value * 12.92
        } else {
            return 1.055 * pow(value, 1.0 / 2.4) - 0.055
        }
    }

    /// CIELAB non-linear transfer function pivot.
    private static func labPivot(_ t: Double) -> Double {
        let delta: Double = 6.0 / 29.0
        if t > pow(delta, 3) {
            return cbrt(t)
        } else {
            return (t / (3.0 * pow(delta, 2))) + (4.0 / 29.0)
        }
    }
}

