import XCTest
@testable import SafeSpaceCore

final class RegionContrastTests: XCTestCase {
    func testUsesMeanCIELABOfEveryEligiblePixelAndIsSymmetric() throws {
        let pixels: [[UInt8]] =
            (0..<10).flatMap { _ in
                Array(repeating: [255, 0, 0, 255], count: 10)
                    + Array(repeating: [0, 0, 255, 255], count: 10)
            }
        let image = SRGBImage(width: 20, height: 10, rgba: pixels.flatMap { $0 })
        let mask = EligibilityMask.all(width: 20, height: 10)
        let left = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let forward = try RegionContrast.measure(image: image, mask: mask, a: left, b: right)
        let reverse = try RegionContrast.measure(image: image, mask: mask, a: right, b: left)
        let red = ColorSpace.sRGBToCIELAB(r: 1, g: 0, b: 0)
        XCTAssertEqual(forward.regionA.meanCielab.l, red.L, accuracy: 1e-12)
        XCTAssertEqual(forward.regionA.meanCielab.a, red.a, accuracy: 1e-12)
        XCTAssertEqual(forward.regionA.meanCielab.b, red.b, accuracy: 1e-12)
        XCTAssertEqual(forward.regionA.eligiblePixelCount, 100)
        XCTAssertEqual(forward.deltaE2000, reverse.deltaE2000, accuracy: 1e-12)
    }

    func testAveragesEveryEligiblePixelInCIELAB() throws {
        let pixels: [[UInt8]] = [[255, 0, 0, 255], [0, 0, 255, 255], [0, 255, 0, 255]]
        let image = SRGBImage(width: 3, height: 1, rgba: pixels.flatMap { $0 })
        let mask = EligibilityMask(width: 3, height: 1, eligible: [true, false, true])
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

        let result = try RegionContrast.measure(image: image, mask: mask, a: full, b: full,
                                                minEligiblePixels: 2)
        let red = ColorSpace.sRGBToCIELAB(r: 1, g: 0, b: 0)
        let green = ColorSpace.sRGBToCIELAB(r: 0, g: 1, b: 0)
        XCTAssertEqual(result.regionA.eligiblePixelCount, 2)
        XCTAssertEqual(result.regionA.meanCielab.l, (red.L + green.L) / 2, accuracy: 1e-12)
        XCTAssertEqual(result.regionA.meanCielab.a, (red.a + green.a) / 2, accuracy: 1e-12)
        XCTAssertEqual(result.regionA.meanCielab.b, (red.b + green.b) / 2, accuracy: 1e-12)
    }

    func testRejectsSmallAndOutOfBoundsRegions() throws {
        let image = SRGBImage(width: 10, height: 10, rgba: Array(repeating: [255, 0, 0, 255], count: 100).flatMap { $0 })
        let mask = EligibilityMask.all(width: 10, height: 10)
        let small = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertThrowsError(try RegionContrast.measure(image: image, mask: mask, a: small, b: full)) {
            XCTAssertEqual($0 as? SafeSpaceError, .regionTooSmall(region: .a, eligiblePixels: 25))
        }
        let invalid = NormalizedRect(x: 0.8, y: 0, width: 0.3, height: 1)
        XCTAssertThrowsError(try RegionContrast.measure(image: image, mask: mask, a: invalid, b: full)) {
            XCTAssertEqual($0 as? SafeSpaceError, .regionOutOfBounds(region: .a))
        }
    }

    func testAddsAndPersistsContrastMeasurements() async throws {
        let store = InMemoryAssessmentStore()
        let actualRoom = await store.createRoom(name: "Room")
        let pixels: [[UInt8]] =
            (0..<10).flatMap { _ in
                Array(repeating: [255, 0, 0, 255], count: 10)
                    + Array(repeating: [0, 0, 255, 255], count: 10)
            }
        let image = SRGBImage(width: 20, height: 10, rgba: pixels.flatMap { $0 })
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version,
                                device: "test", os: "test")
        let output = try await AssessmentPipeline.run(imageData: image.pngData(), source: .library,
                                                      roomID: actualRoom.id, producer: producer)
        let saved = try await store.save(output)
        let left = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let updated = try AssessmentPipeline.addContrast(to: saved, image: output.storedImage!,
                                                         mask: output.mask, a: left, b: right)
        try await store.update(updated)
        let reopened = try await store.load(assessmentID: saved.assessmentId)
        let result = try XCTUnwrap(reopened.record.steps.contrast.result?.decoded(as: ContrastResult.self))
        XCTAssertEqual(result.measurements.count, 1)
        XCTAssertEqual(reopened.record.steps.contrast.status, .completed)
        XCTAssertTrue(reopened.record.findings.contains { $0.kind == .contrast })
        XCTAssertEqual(try AssessmentJSON.decode(AssessmentJSON.encode(reopened.record)), reopened.record)
    }
}
