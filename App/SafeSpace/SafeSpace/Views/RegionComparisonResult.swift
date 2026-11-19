import Foundation
import SwiftUI
import SafeSpaceCore

struct RegionComparisonResult: View {
    let measurement: ContrastMeasurement
    let method: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Region A vs. Region B").font(.headline)
            HStack(spacing: 12) {
                swatch("Region A", lab: measurement.region1.cielab)
                swatch("Region B", lab: measurement.region2.cielab)
            }
            Text("ΔE00 = \(displayedDeltaE.formatted(.number.precision(.fractionLength(1))))")
                .font(.title2.bold()).monospacedDigit()
            if let band = ContrastDifferenceBand(deltaE: displayedDeltaE) {
                Text(band.title).font(.headline)
                Text(band.guidance).font(.subheadline)
            }
            Text("These ranges are a rough visual guide, not official CIE cutoffs or a judgment about whether someone will see the difference.")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("Measurement details") {
                Text(methodDescription)
                Text("A: \(labText(measurement.region1.cielab))")
                Text("B: \(labText(measurement.region2.cielab))")
                Text("Lighting, shadows, camera processing, surrounding colors and viewing conditions affect interpretation. This is not a pass/fail result.")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private var displayedDeltaE: Double {
        (measurement.deltaE * 10).rounded() / 10
    }

    private var methodDescription: String {
        if method == RegionContrast.methodName { return "CIEDE2000 · Component-wise median CIELAB of eligible sRGB pixels" }
        if method == RegionContrast.legacyMethodName { return "CIEDE2000 · Mean CIELAB of eligible sRGB pixels (legacy)" }
        return "CIEDE2000 · CIELAB of eligible sRGB pixels"
    }

    private func swatch(_ title: String, lab: LabValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 10)
                .fill(displayColor(lab))
                .frame(height: 48)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.2)) }
                .accessibilityHidden(true)
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labText(_ lab: LabValue) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return "L* \(lab.l.formatted(style)) · a* \(lab.a.formatted(style)) · b* \(lab.b.formatted(style))"
    }

    private func displayColor(_ lab: LabValue) -> Color {
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500, fz = fy - lab.b / 200
        let d = 6.0 / 29.0
        func inverse(_ v: Double) -> Double {
            v > d ? v * v * v : 3 * d * d * (v - 4.0 / 29.0)
        }
        let x = 0.95047 * inverse(fx), y = inverse(fy), z = 1.08883 * inverse(fz)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
        }
        return Color(.sRGB, red: encode(3.2404542*x - 1.5371385*y - 0.4985314*z),
                     green: encode(-0.9692660*x + 1.8760108*y + 0.0415560*z),
                     blue: encode(0.0556434*x - 0.2040259*y + 1.0572252*z), opacity: 1)
    }
}
