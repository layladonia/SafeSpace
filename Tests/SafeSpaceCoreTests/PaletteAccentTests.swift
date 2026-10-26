import Foundation
import XCTest
@testable import SafeSpaceCore

final class PaletteAccentTests: XCTestCase {
    func testRedAccentSurvivesLoadingAndExtraction() async throws {
        // A controlled image:
        // 95 neutral pixels and 5 clearly red pixels.
        var rgba: [UInt8] = []

        for _ in 0..<95 {
            rgba.append(contentsOf: [190, 190, 190, 255])
        }

        for _ in 0..<5 {
            rgba.append(contentsOf: [220, 20, 40, 255])
        }

        let input = SRGBImage(
            width: 10,
            height: 10,
            rgba: rgba
        )

        let data = input.pngData()

        // First check preprocessing independently of clustering.
        let loaded = try ImageLoader.load(
            data: data,
            source: .library
        )

        let redPixelCount = stride(
            from: 0,
            to: loaded.image.rgba.count,
            by: 4
        ).filter { offset in
            let r = Int(loaded.image.rgba[offset])
            let g = Int(loaded.image.rgba[offset + 1])
            let b = Int(loaded.image.rgba[offset + 2])

            return r > 150 && r > g * 2 && r > b * 2
        }.count

        XCTAssertEqual(
            redPixelCount,
            5,
            "The loader did not preserve the known red pixels."
        )

        let producer = Producer(
            kind: "app",
            appVersion: "test",
            coreVersion: SafeSpaceCore.version,
            device: "unit-test",
            os: "unit-test"
        )

        let methods: [PaletteMethod] = [
            .kmeansPP,
            .medianCut
        ]

        for method in methods {
            var options = PipelineOptions()
            options.paletteMethod = method

            let output = try await AssessmentPipeline.run(
                imageData: data,
                source: .library,
                roomID: UUID().uuidString.lowercased(),
                producer: producer,
                options: options
            )

            let palette = try XCTUnwrap(
                output.record.steps.palette.result,
                "\(method.rawValue) did not produce a palette."
            )

            let red = palette.colors.first { color in
                guard color.srgb8.count == 3 else {
                    return false
                }

                let r = Int(color.srgb8[0])
                let g = Int(color.srgb8[1])
                let b = Int(color.srgb8[2])

                return r > 150 && r > g * 2 && r > b * 2
            }

            let redColor = try XCTUnwrap(
                red,
                "\(method.rawValue) lost the known red accent."
            )

            XCTAssertEqual(
                redColor.share,
                0.05,
                accuracy: 0.000001,
                "\(method.rawValue) returned the wrong red share."
            )
        }
    }
}