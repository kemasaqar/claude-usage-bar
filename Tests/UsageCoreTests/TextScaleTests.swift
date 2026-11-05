import XCTest
@testable import UsageCore

final class TextScaleTests: XCTestCase {
    func testStepsAreFivePercentFrom80To150() {
        XCTAssertEqual(TextScale.steps.first, 80)
        XCTAssertEqual(TextScale.steps.last, 150)
        XCTAssertTrue(zip(TextScale.steps, TextScale.steps.dropFirst()).allSatisfy { $1 - $0 == 5 })
        XCTAssertTrue(TextScale.steps.contains(TextScale.defaultPercent))
    }

    func testStoredValuesSnapToAStep() {
        XCTAssertEqual(TextScale.sanitize(nil), 100)
        XCTAssertEqual(TextScale.sanitize(115), 115)
        XCTAssertEqual(TextScale.sanitize(117), 115)
        XCTAssertEqual(TextScale.sanitize(118), 120)
        XCTAssertEqual(TextScale.sanitize(0), 80)      // also an unset Int default
        XCTAssertEqual(TextScale.sanitize(400), 150)
    }

    func testFactor() {
        XCTAssertEqual(TextScale.factor(nil), 1)
        XCTAssertEqual(TextScale.factor(115), 1.15, accuracy: 0.0001)
        XCTAssertEqual(TextScale.factor(999), 1.5, accuracy: 0.0001)
    }
}
