import XCTest
@testable import SafeSpaceCore

final class PrivacyMaskDerivationTests: XCTestCase {
    private func region(x: Double, width: Double) -> DetectedRegion {
        .init(kind: "person", rect: .init(x: x, y: 0, width: width, height: 1), confidence: 1)
    }

    func testEmptyRegionsKeepEveryPixel() throws {
        let mask = try PrivacyMasking.deriveMask(width: 8, height: 8, regions: [])
        XCTAssertEqual(mask.eligibleCount, 64)
        XCTAssertEqual(PrivacyMasking.maskedShare(of: mask), 0)
    }

    func testDuplicateRectanglesAreCountedOnce() throws {
        let box = region(x: 0, width: 0.5)
        let mask = try PrivacyMasking.deriveMask(width: 8, height: 8, regions: [box, box])
        XCTAssertEqual(mask.eligibleCount, 32)
        XCTAssertEqual(PrivacyMasking.maskedShare(of: mask), 0.5)
    }

    func testFullImageMask() throws {
        let mask = try PrivacyMasking.deriveMask(width: 8, height: 8, regions: [region(x: 0, width: 1)])
        XCTAssertEqual(mask.eligibleCount, 0)
        XCTAssertEqual(PrivacyMasking.maskedShare(of: mask), 1)
    }

    func testMatchesExistingRasterizationForFractionalRectangles() throws {
        let regions = [region(x: 0.13, width: 0.29), region(x: 0.3, width: 0.4)]
        let expected = EligibilityMask.all(width: 13, height: 9).excluding(regions.map(\.rect))
        let actual = try PrivacyMasking.deriveMask(width: 13, height: 9, regions: regions)
        XCTAssertEqual(actual, expected)
    }

    func testInvalidInputIsRejected() {
        XCTAssertThrowsError(try PrivacyMasking.deriveMask(width: 0, height: 8, regions: []))
        XCTAssertThrowsError(try PrivacyMasking.deriveMask(width: -1, height: 8, regions: []))
        XCTAssertThrowsError(try PrivacyMasking.deriveMask(width: Int.max, height: 2, regions: []))
        XCTAssertThrowsError(try PrivacyMasking.deriveMask(width: 8, height: 8,
                                                         regions: [region(x: .nan, width: 0.5)]))
    }
}
