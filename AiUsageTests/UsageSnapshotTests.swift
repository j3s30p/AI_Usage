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

    func testWeeklyWindowIsOptionalAndClampedIndependently() {
        let date = Date(timeIntervalSince1970: 1_000)
        let weekly = UsageLimitWindow(
            remainingFraction: 1.4,
            resetAt: date.addingTimeInterval(7_200)
        )
        let snapshot = UsageSnapshot(
            provider: .codex,
            remainingFraction: 0.51,
            resetAt: date.addingTimeInterval(3_600),
            weekly: weekly,
            fetchedAt: date
        )

        XCTAssertEqual(snapshot.remainingPercentage, 51)
        XCTAssertEqual(snapshot.weekly?.remainingFraction, 1)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 100)
        XCTAssertEqual(snapshot.weekly?.resetAt, date.addingTimeInterval(7_200))
    }

    func testCurrentSnapshotRequiresFutureResetAndFreshCapture() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = UsageSnapshot(
            provider: .claude,
            remainingFraction: 0.5,
            resetAt: now.addingTimeInterval(60),
            fetchedAt: now.addingTimeInterval(-899)
        )
        let stale = UsageSnapshot(
            provider: .claude,
            remainingFraction: 0.5,
            resetAt: now.addingTimeInterval(60),
            fetchedAt: now.addingTimeInterval(-901)
        )
        let expired = UsageSnapshot(
            provider: .claude,
            remainingFraction: 0.5,
            resetAt: now,
            fetchedAt: now
        )

        XCTAssertTrue(fresh.isCurrent(at: now, maximumAge: 900))
        XCTAssertFalse(stale.isCurrent(at: now, maximumAge: 900))
        XCTAssertFalse(expired.isCurrent(at: now, maximumAge: 900))
    }
}
