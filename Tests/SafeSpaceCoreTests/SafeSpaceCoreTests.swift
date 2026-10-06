import XCTest
@testable import SafeSpaceCore

final class SafeSpaceCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(SafeSpaceCore.version.isEmpty)
    }
}
