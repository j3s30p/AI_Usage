import Foundation
import XCTest
@testable import AiUsage

final class LiveUsageSmokeTests: XCTestCase {
    func testLiveCodexAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let snapshot = try await CodexUsageProvider().fetchUsage()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertGreaterThan(snapshot.menuBarWindow.resetAt, Date())
    }

    func testLiveClaudeStatusLineAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let snapshot = try await ClaudeUsageProvider().fetchUsage(mode: .statusLine)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertGreaterThan(snapshot.menuBarWindow.resetAt, Date())
    }

    func testLiveClaudeOAuthAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let response = try await ClaudeOAuthUsageClient().fetchUsage()
        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertGreaterThan(snapshot.menuBarWindow.resetAt, Date())
    }
}
