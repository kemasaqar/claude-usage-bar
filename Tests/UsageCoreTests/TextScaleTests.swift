import XCTest
@testable import UsageCore

final class TextScaleTests: XCTestCase {
    func testStepsAreTenPercentFrom80To150() {
        XCTAssertEqual(TextScale.steps, [80, 90, 100, 110, 120, 130, 140, 150])
        XCTAssertTrue(TextScale.steps.contains(TextScale.defaultPercent))
    }

    func testStoredValuesSnapToAStep() {
        XCTAssertEqual(TextScale.sanitize(nil), 100)
        XCTAssertEqual(TextScale.sanitize(120), 120)
        XCTAssertEqual(TextScale.sanitize(117), 120)
        XCTAssertEqual(TextScale.sanitize(112), 110)
        XCTAssertEqual(TextScale.sanitize(125), 120)   // an old 5% step: halfway goes down
        XCTAssertEqual(TextScale.sanitize(0), 80)      // also an unset Int default
        XCTAssertEqual(TextScale.sanitize(400), 150)
    }

    func testFactor() {
        XCTAssertEqual(TextScale.factor(nil), 1)
        XCTAssertEqual(TextScale.factor(130), 1.3, accuracy: 0.0001)
        XCTAssertEqual(TextScale.factor(999), 1.5, accuracy: 0.0001)
    }
}
