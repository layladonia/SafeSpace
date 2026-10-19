// Perceptual color difference between two CIELAB colors
import Foundation

public enum ColorDifference {
    /// CIEDE2000 color difference (ΔE00) between two CIELAB colors.
    ///
    /// Follows Sharma, Wu & Dalal (2005), "The CIEDE2000 Color-Difference Formula:
    /// Implementation Notes, Supplementary Test Data, and Mathematical Observations".
    /// kL, kC, kH are the parametric weighting factors (1 under reference conditions).
    public static func ciede2000(
        _ lab1: PerceptualColor,
        _ lab2: PerceptualColor,
        kL: Double = 1.0,
        kC: Double = 1.0,
        kH: Double = 1.0
    ) -> Double {
        let pow25To7 = pow(25.0, 7.0)

        // Step 1: adjusted a', C', h'
        let C1 = hypot(lab1.a, lab1.b)
        let C2 = hypot(lab2.a, lab2.b)
        let CBar = (C1 + C2) / 2.0
        let CBar7 = pow(CBar, 7.0)
        let G = 0.5 * (1.0 - sqrt(CBar7 / (CBar7 + pow25To7)))

        let a1p = (1.0 + G) * lab1.a
        let a2p = (1.0 + G) * lab2.a
        let C1p = hypot(a1p, lab1.b)
        let C2p = hypot(a2p, lab2.b)
        let h1p = hueAngleDegrees(a: a1p, b: lab1.b)
        let h2p = hueAngleDegrees(a: a2p, b: lab2.b)

        // Step 2: ΔL', ΔC', ΔH'
        let dLp = lab2.L - lab1.L
        let dCp = C2p - C1p

        let chromaProduct = C1p * C2p
        var dhp = 0.0
        if chromaProduct != 0 {
            dhp = h2p - h1p
            if dhp > 180.0 {
                dhp -= 360.0
            } else if dhp < -180.0 {
                dhp += 360.0
            }
        }
        let dHp = 2.0 * sqrt(chromaProduct) * sin(radians(dhp / 2.0))

        // Step 3: weighting functions and rotation term
        let LBarp = (lab1.L + lab2.L) / 2.0
        let CBarp = (C1p + C2p) / 2.0

        var hBarp = h1p + h2p
        if chromaProduct != 0 {
            if abs(h1p - h2p) <= 180.0 {
                hBarp /= 2.0
            } else if hBarp < 360.0 {
                hBarp = (hBarp + 360.0) / 2.0
            } else {
                hBarp = (hBarp - 360.0) / 2.0
            }
        }

        let T = 1.0
            - 0.17 * cos(radians(hBarp - 30.0))
            + 0.24 * cos(radians(2.0 * hBarp))
            + 0.32 * cos(radians(3.0 * hBarp + 6.0))
            - 0.20 * cos(radians(4.0 * hBarp - 63.0))

        let dTheta = 30.0 * exp(-pow((hBarp - 275.0) / 25.0, 2.0))
        let CBarp7 = pow(CBarp, 7.0)
        let RC = 2.0 * sqrt(CBarp7 / (CBarp7 + pow25To7))
        let LBarpMinus50Sq = pow(LBarp - 50.0, 2.0)
        let SL = 1.0 + (0.015 * LBarpMinus50Sq) / sqrt(20.0 + LBarpMinus50Sq)
        let SC = 1.0 + 0.045 * CBarp
        let SH = 1.0 + 0.015 * CBarp * T
        let RT = -sin(radians(2.0 * dTheta)) * RC

        let lTerm = dLp / (kL * SL)
        let cTerm = dCp / (kC * SC)
        let hTerm = dHp / (kH * SH)

        return sqrt(lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + RT * cTerm * hTerm)
    }

    /// Hue angle in degrees, in [0, 360). Defined as 0 when a = b = 0.
    private static func hueAngleDegrees(a: Double, b: Double) -> Double {
        if a == 0 && b == 0 { return 0.0 }
        let h = atan2(b, a) * 180.0 / .pi
        return h >= 0 ? h : h + 360.0
    }

    private static func radians(_ degrees: Double) -> Double {
        return degrees * .pi / 180.0
    }
}
