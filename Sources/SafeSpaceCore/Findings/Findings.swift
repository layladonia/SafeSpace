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
    public static func generate(for record: AssessmentRecord) -> [Finding] {
        var findings: [Finding] = []
        func append(_ kind: FindingKind, _ template: String, _ text: String, _ sources: [String] = []) {
            precondition(!containsBannedTerm(text))
            findings.append(.init(id: "f\(findings.count + 1)", kind: kind, templateId: template,
                                  templateVersion: 1, text: text, sources: sources))
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
}
