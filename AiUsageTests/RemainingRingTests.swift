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

    func testZeroRemainingKeepsOneDegreeVisible() {
        XCTAssertEqual(
            RemainingRing.zeroRemainingDisplayFraction,
            1.0 / 360.0,
            accuracy: 0.000_001
        )
    }

    func testDisplayedZeroMatchesRoundedPercentageBoundary() {
        XCTAssertTrue(RemainingRing.isDisplayedAsZero(0.004))
        XCTAssertFalse(RemainingRing.isDisplayedAsZero(0.005))
    }
}
