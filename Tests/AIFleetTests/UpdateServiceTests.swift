import XCTest
@testable import AIFleet

final class UpdateServiceTests: XCTestCase {
    func testSemanticVersionOrdering() throws {
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("1.9.9")),
            try XCTUnwrap(AppSemanticVersion("2.0.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("2.0.0")),
            try XCTUnwrap(AppSemanticVersion("2.1.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("2.1.0")),
            try XCTUnwrap(AppSemanticVersion("2.1.1"))
        )
    }

    func testSemanticVersionRejectsUnsupportedFormats() {
        XCTAssertNil(AppSemanticVersion("v1.2.3"))
        XCTAssertNil(AppSemanticVersion("1.2"))
        XCTAssertNil(AppSemanticVersion("1.2.3-beta.1"))
        XCTAssertNil(AppSemanticVersion("01.2.3"))
        XCTAssertNil(AppSemanticVersion("1.-2.3"))
    }
}
