import Foundation

public enum Findings {
    public static let bannedTerms = ["lux", "safe", "unsafe", "suitable", "unsuitable", "dementia", "autism",
        "autistic", "diagnose", "certify", "compliant", "WCAG pass", "calming", "therapeutic"]
    public static func containsBannedTerm(_ text: String) -> Bool {
        bannedTerms.contains { term in
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}_])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
    /// Palette colors with at least this share get a dominant-color sentence (rank 1 always does).
    public static let dominantShareMin = 0.15
    public static let maxDominant = 3
    /// Accents: small but strongly colored groups.
    public static let accentShareMax = 0.10
    public static let accentChromaMin = 0.10
    public static let maxAccents = 2

    public static func generate(for record: AssessmentRecord) -> [Finding] {
        var findings: [Finding] = []
        func append(_ kind: FindingKind, _ template: String, _ text: String, _ sources: [String] = []) {
            precondition(!containsBannedTerm(text))
            findings.append(.init(id: "f\(findings.count + 1)", kind: kind, templateId: template,
                                  templateVersion: 1, text: text, sources: sources))
        }
        if record.steps.palette.status == .completed, let palette = record.steps.palette.result {
            let colors = palette.colors
            func sources(_ i: Int) -> [String] {
                ["/steps/palette/result/colors/\(i)/share", "/steps/palette/result/colors/\(i)/oklch"]
            }
            let overall = overallTemplate(colors)
            append(.paletteOverall, "palette.overall.\(overall.id)", overall.text, colors.indices.flatMap(sources))
            for (i, color) in colors.enumerated().prefix(maxDominant) where i == 0 || color.share >= dominantShareMin {
                let text = i == 0
                    ? "The largest color group covers \(percent(color.share)) of the photo: \(article(colorName(color.oklch)))."
                    : "Another large group covers \(percent(color.share)): \(article(colorName(color.oklch)))."
                append(.paletteDominant, i == 0 ? "palette.dominant.largest" : "palette.dominant.other", text, sources(i))
            }
            let accents = colors.indices.filter { i in
                i > 0 && colors[i].share < accentShareMax && colors[i].oklch.c >= accentChromaMin
            }
            for i in accents.prefix(maxAccents) {
                append(.paletteAccent, "palette.accent.strong",
                       "A small area of strong color (\(article(colorName(colors[i].oklch)))) covers \(percent(colors[i].share)) of the photo.",
                       sources(i))
            }
        }
        append(.limitation, "limitation.photo_not_room",
               "These colors describe this photo, not the room itself. Lighting and the camera change how colors look.")
        if record.steps.anonymization.status != .completed {
            append(.limitation, "limitation.people_not_masked",
                   "Faces and people have not been hidden or excluded from these color statistics.")
        }
        append(.limitation, "limitation.palette_not_contrast",
               "Pixel shares are not measurements of physical surface area. A palette does not compare the color difference between two selected areas.")
        if record.steps.quality.status != .completed {
            append(.limitation, "limitation.quality_not_checked", "Photo quality has not been checked in this build.")
        }
        return findings
    }

    /// "about 41%", or "less than 1%" so a small share is never shown as 0%.
    static func percent(_ share: Double) -> String {
        let value = Int((share * 100).rounded())
        return value < 1 ? "less than 1%" : "about \(value)%"
    }
    static func article(_ name: String) -> String {
        "aeiou".contains(name.first ?? "x") ? "an \(name)" : "a \(name)"
    }

    /// Share-weighted lightness and chroma of the retained colors.
    static func overallTemplate(_ colors: [PaletteColor]) -> (id: String, text: String) {
        let total = colors.reduce(0) { $0 + $1.share }
        let l = colors.reduce(0) { $0 + $1.share * $1.oklch.l } / total
        let c = colors.reduce(0) { $0 + $1.share * $1.oklch.c } / total
        let lightness: (id: String, text: String) =
            l >= 0.70 ? ("light", "light") : l >= 0.45 ? ("medium", "medium in lightness") : ("dark", "dark")
        let chroma: (id: String, text: String) =
            c < 0.03 ? ("low_color", "low in color") : c < 0.08 ? ("moderate_color", "moderately colorful")
            : ("strong_color", "strongly colorful")
        return ("\(lightness.id)_\(chroma.id)",
                "Overall, the colors in this photo are mostly \(lightness.text) and \(chroma.text).")
    }

    /// Plain color name from OKLCh. Below `neutralChromaMax` no hue is named, which also covers
    /// achromatic colors whose stored `h` is null.
    public static let neutralChromaMax = 0.02
    static func colorName(_ lch: LChValue) -> String {
        let l = lch.l
        guard let h = lch.h, lch.c >= neutralChromaMax else {
            if l >= 0.93 { return "near-white" }
            if l < 0.25 { return "near-black" }
            return "\(lightnessWord(l)) gray"
        }
        let muted = lch.c < 0.06
        var hue: String
        switch h {
        case 40..<75: hue = l < 0.6 ? "brown" : "orange"
        case 75..<120: hue = l < 0.6 ? "olive" : "yellow"
        case 120..<175: hue = "green"
        case 175..<225: hue = "teal"
        case 225..<280: hue = "blue"
        case 280..<345: hue = l >= 0.75 ? "pink" : "purple"
        default: hue = l >= 0.75 ? "pink" : "red"
        }
        // Warm, low-color tones read as beige or tan rather than "muted orange".
        if muted, (30..<110).contains(h) { hue = l >= 0.78 ? "beige" : l >= 0.55 ? "tan" : "brown" }
        else if muted { hue = "grayish \(hue)" }
        return "\(lightnessWord(l)) \(hue)"
    }
    static func lightnessWord(_ l: Double) -> String {
        l < 0.35 ? "very dark" : l < 0.5 ? "dark" : l < 0.7 ? "medium" : l < 0.85 ? "light" : "very light"
    }
}
