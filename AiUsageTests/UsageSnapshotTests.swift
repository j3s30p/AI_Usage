import Foundation
import XCTest
@testable import AiUsage

final class UsageSnapshotTests: XCTestCase {
    func testRemainingFractionIsClampedAndRounded() {
        let date = Date(timeIntervalSince1970: 1_000)

        let over = UsageSnapshot(
            provider: .codex,
            remainingFraction: 1.4,
            resetAt: date,
            fetchedAt: date
        )
        let under = UsageSnapshot(
            provider: .claude,
            remainingFraction: -0.2,
            resetAt: date,
            fetchedAt: date
        )
        let regular = UsageSnapshot(
            provider: .codex,
            remainingFraction: 0.724,
            resetAt: date,
            fetchedAt: date
        )

        XCTAssertEqual(over.remainingFraction, 1)
        XCTAssertEqual(over.remainingPercentage, 100)
        XCTAssertEqual(under.remainingFraction, 0)
        XCTAssertEqual(under.remainingPercentage, 0)
        XCTAssertEqual(regular.remainingPercentage, 72)
    }

    func testNonFiniteRemainingFractionFallsBackToZero() {
        let date = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            provider: .codex,
            remainingFraction: .nan,
            resetAt: date,
            fetchedAt: date
        )

        XCTAssertEqual(snapshot.remainingFraction, 0)
    }
}
