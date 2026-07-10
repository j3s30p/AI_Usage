import XCTest
@testable import AiUsage

final class RemainingRingTests: XCTestCase {
    func testRemainingRingOpensClockwiseFromTwelve() {
        XCTAssertEqual(RemainingRing.trimStart(forRemaining: 1), 0)
        XCTAssertEqual(RemainingRing.trimStart(forRemaining: 0.75), 0.25)
        XCTAssertEqual(RemainingRing.trimStart(forRemaining: 0.25), 0.75)
        XCTAssertEqual(RemainingRing.trimStart(forRemaining: 0), 1)
    }

    func testRemainingRingNormalizesInvalidValues() {
        XCTAssertEqual(RemainingRing.normalizedRemaining(-1), 0)
        XCTAssertEqual(RemainingRing.normalizedRemaining(2), 1)
        XCTAssertEqual(RemainingRing.normalizedRemaining(.infinity), 0)
    }
}
