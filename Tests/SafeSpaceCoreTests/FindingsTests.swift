import XCTest
@testable import SafeSpaceCore

final class FindingsTests: XCTestCase {
    /// One row of pixels, `count` of each color, analyzed with merging and dropping turned off.
    private func record(_ groups: [([UInt8], Int)]) async throws -> AssessmentRecord {
        let pixels: [[UInt8]] = groups.flatMap { color, count in Array(repeating: color + [UInt8(255)], count: count) }
        let image = SRGBImage(width: pixels.count, height: 1, rgba: pixels.flatMap { $0 })
        var options = PipelineOptions()
        options.paletteParams.mergeDeltaEOk = 0
        options.paletteParams.minShare = 0
        let producer = Producer(kind: "cli", appVersion: nil, coreVersion: SafeSpaceCore.version, device: "test", os: "test")
        return try await AssessmentPipeline.run(imageData: image.pngData(), source: .file, roomID: "cli",
                                                producer: producer, options: options).record
    }
    private let beige: [UInt8] = [220, 205, 180], brown: [UInt8] = [90, 60, 40]
    private let gray: [UInt8] = [128, 128, 128], red: [UInt8] = [220, 20, 40]

    func testBannedTermsAreWholeWordAndCaseInsensitive() {
        XCTAssertTrue(Findings.containsBannedTerm("This room is SAFE."))
        XCTAssertTrue(Findings.containsBannedTerm("A calming blue."))
        XCTAssertTrue(Findings.containsBannedTerm("It is WCAG pass level."))
        XCTAssertFalse(Findings.containsBannedTerm("Colors were measured safely."))
        XCTAssertFalse(Findings.containsBannedTerm("A luxurious beige."))
    }

    func testDominantAndAccentFindings() async throws {
        let r = try await record([(beige, 60), (brown, 20), (gray, 15), (red, 5)])
        let byKind = Dictionary(grouping: r.findings, by: \.kind)
        XCTAssertEqual(byKind[.paletteOverall]?.count, 1)
        let dominant = try XCTUnwrap(byKind[.paletteDominant])
        XCTAssertEqual(dominant.map(\.templateId), ["palette.dominant.largest", "palette.dominant.other", "palette.dominant.other"])
        XCTAssertTrue(dominant[0].text.contains("about 60%") && dominant[0].text.contains("beige"), dominant[0].text)
        XCTAssertTrue(dominant[1].text.contains("about 20%") && dominant[1].text.contains("brown"), dominant[1].text)
        XCTAssertTrue(dominant[2].text.contains("gray"), dominant[2].text)
        let accent = try XCTUnwrap(byKind[.paletteAccent]?.first)
        XCTAssertTrue(accent.text.contains("red") && accent.text.contains("about 5%"), accent.text)
        // Palette sentences come before the limitations, in display order.
        XCTAssertEqual(r.findings.first?.kind, .paletteOverall)
        XCTAssertEqual(r.findings.map(\.id), r.findings.indices.map { "f\($0 + 1)" })
    }

    func testEveryPercentInTheTextMatchesItsSource() async throws {
        let r = try await record([(beige, 47), (brown, 31), (gray, 13), (red, 9)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: AssessmentJSON.encoder().encode(r)) as? [String: Any])
        for finding in r.findings where finding.kind == .paletteDominant || finding.kind == .paletteAccent {
            let pointer = try XCTUnwrap(finding.sources.first { $0.hasSuffix("/share") })
            let share = try XCTUnwrap(resolve(pointer, in: object) as? Double)
            XCTAssertTrue(finding.text.contains("about \(Int((share * 100).rounded()))%"), finding.text)
        }
        try AssessmentValidator.validate(r)
    }

    func testNeutralColorsNeverNameAHue() {
        for l in stride(from: 0.0, through: 1.0, by: 0.05) {
            for c in [0.0, 0.001, 0.015] {
                let name = Findings.colorName(LChValue(l: l, c: c, h: c < 0.002 ? nil : 30))
                for hue in ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "beige", "tan", "brown"] {
                    XCTAssertFalse(name.contains(hue), name)
                }
            }
        }
    }

    func testColorNames() {
        func name(_ rgb: [Double]) -> String {
            let lab = ColorSpace.sRGBToOKLab(r: rgb[0], g: rgb[1], b: rgb[2])
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            var h = atan2(lab.b, lab.a) * 180 / .pi
            if h < 0 { h += 360 }
            return Findings.colorName(LChValue(l: lab.L, c: c, h: c < 0.002 ? nil : h))
        }
        XCTAssertEqual(name([1, 1, 1]), "near-white")
        XCTAssertEqual(name([0, 0, 0]), "near-black")
        XCTAssertTrue(name([0.5, 0.5, 0.5]).hasSuffix("gray"))
        XCTAssertTrue(name([0.86, 0.08, 0.16]).hasSuffix("red"))
        XCTAssertTrue(name([0.1, 0.3, 0.8]).hasSuffix("blue"))
        XCTAssertTrue(name([0.2, 0.6, 0.3]).hasSuffix("green"))
        XCTAssertTrue(name([0.86, 0.80, 0.71]).hasSuffix("beige"))
    }

    func testNoTemplateEmitsABannedTerm() {
        // Every lightness/chroma/hue combination the templates can name, checked once per distinct text.
        var texts: Set<String> = []
        for l in stride(from: 0.0, through: 1.0, by: 0.01) {
            for c in stride(from: 0.0, through: 0.3, by: 0.005) {
                for h in stride(from: 0.0, to: 360, by: 1) {
                    let lch = LChValue(l: l, c: c, h: c < 0.002 ? nil : h)
                    let color = PaletteColor(id: "c1", rank: 1, share: 1, pixelCount: 1, hex: "#000000", srgb8: [0, 0, 0],
                        oklab: .init(l: l, a: 0, b: 0), oklch: lch, cielab: .init(l: 0, a: 0, b: 0))
                    texts.insert(Findings.colorName(lch))
                    texts.insert(Findings.overallTemplate([color]).text)
                }
            }
        }
        for text in texts { XCTAssertFalse(Findings.containsBannedTerm(text), text) }
    }

    func testFailedPaletteHasOnlyLimitations() async throws {
        var r = try await record([(gray, 4)])
        r.steps.palette = .init(status: .failed, reason: .paletteExtractionFailed, durationMs: 0,
                                method: r.steps.palette.method, result: nil)
        r.findings = Findings.generate(for: r)
        // Contract §3.4: with a failed palette, findings may describe only quality and limitations.
        XCTAssertTrue(r.findings.allSatisfy { $0.kind == .limitation || $0.kind == .quality })
        XCTAssertFalse(r.findings.contains { $0.kind.rawValue.hasPrefix("palette") })
        try AssessmentValidator.validate(r)
    }

    private func resolve(_ pointer: String, in root: Any) -> Any? {
        var value: Any? = root
        for part in pointer.dropFirst().split(separator: "/") {
            if let o = value as? [String: Any] { value = o[String(part)] }
            else if let a = value as? [Any], let i = Int(part), a.indices.contains(i) { value = a[i] }
            else { return nil }
        }
        return value
    }
}
