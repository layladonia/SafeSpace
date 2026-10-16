import XCTest
@testable import SafeSpaceCore

final class ColorDifferenceTests: XCTestCase {
    private struct SharmaData: Decodable {
        struct Pair: Decodable {
            let lab1: [Double]
            let lab2: [Double]
            let deltaE: Double
        }
        let pairs: [Pair]
    }

    private struct PythonReference: Decodable {
        struct Sample: Decodable {
            let srgb8: [Int]
            let oklab: [Double]
            let cielab: [Double]
        }
        let samples: [Sample]
    }

    /// reference/ at the repository root, shared with the Python reference tests.
    private static let referenceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("reference")

    private func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let data = try Data(contentsOf: Self.referenceDir.appendingPathComponent(name))
        return try JSONDecoder().decode(type, from: data)
    }

    private func lab(_ v: [Double]) -> PerceptualColor {
        return PerceptualColor(L: v[0], a: v[1], b: v[2])
    }

    func testSharmaReferencePairs() throws {
        let pairs = try load(SharmaData.self, "sharma_ciede2000.json").pairs
        XCTAssertEqual(pairs.count, 34)

        for (i, pair) in pairs.enumerated() {
            let forward = ColorDifference.ciede2000(lab(pair.lab1), lab(pair.lab2))
            let reverse = ColorDifference.ciede2000(lab(pair.lab2), lab(pair.lab1))
            XCTAssertEqual(forward, pair.deltaE, accuracy: 0.0001, "Sharma pair \(i + 1)")
            XCTAssertEqual(reverse, pair.deltaE, accuracy: 0.0001, "Sharma pair \(i + 1) (reversed)")
        }
    }

    func testIdenticalColorsHaveZeroDifference() {
        let color = PerceptualColor(L: 53.241, a: 80.092, b: 67.203)
        XCTAssertEqual(ColorDifference.ciede2000(color, color), 0.0)
    }

    func testSwiftMatchesPythonReference() throws {
        let samples = try load(PythonReference.self, "python_reference.json").samples
        XCTAssertFalse(samples.isEmpty)

        for sample in samples {
            let r = Double(sample.srgb8[0]) / 255.0
            let g = Double(sample.srgb8[1]) / 255.0
            let b = Double(sample.srgb8[2]) / 255.0

            let oklab = ColorSpace.sRGBToOKLab(r: r, g: g, b: b)
            XCTAssertEqual(oklab.L, sample.oklab[0], accuracy: 0.001, "OKLab L for \(sample.srgb8)")
            XCTAssertEqual(oklab.a, sample.oklab[1], accuracy: 0.001, "OKLab a for \(sample.srgb8)")
            XCTAssertEqual(oklab.b, sample.oklab[2], accuracy: 0.001, "OKLab b for \(sample.srgb8)")

            let cielab = ColorSpace.sRGBToCIELAB(r: r, g: g, b: b)
            XCTAssertEqual(cielab.L, sample.cielab[0], accuracy: 0.001, "CIELAB L for \(sample.srgb8)")
            XCTAssertEqual(cielab.a, sample.cielab[1], accuracy: 0.001, "CIELAB a for \(sample.srgb8)")
            XCTAssertEqual(cielab.b, sample.cielab[2], accuracy: 0.001, "CIELAB b for \(sample.srgb8)")
        }
    }
}
