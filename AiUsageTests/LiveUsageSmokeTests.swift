import Foundation
import XCTest
@testable import AiUsage

final class LiveUsageSmokeTests: XCTestCase {
    func testLiveCodexFiveHourUsageWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let snapshot = try await CodexUsageProvider().fetchUsage()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertTrue((0...1).contains(snapshot.remainingFraction))
        XCTAssertGreaterThan(snapshot.resetAt, Date().addingTimeInterval(-300))
    }

    func testLiveClaudeFiveHourUsageWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let snapshot = try await ClaudeUsageProvider().fetchUsage()

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.remainingFraction))
        XCTAssertGreaterThan(snapshot.resetAt, Date().addingTimeInterval(-300))
    }

    func testLiveClaudeCLIProbeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let response = try await ClaudeCLIUsageProbe().fetchUsage()
        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.remainingFraction))
        XCTAssertGreaterThan(snapshot.resetAt, Date())
    }
}
