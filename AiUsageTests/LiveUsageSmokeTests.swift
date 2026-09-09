import Darwin
import Foundation
import XCTest
@testable import AiUsage

final class LiveUsageSmokeTests: XCTestCase {
    func testLiveCodexAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        guard let executableURL = ExecutableLocator.locate("codex") else {
            throw XCTSkip("Codex executable is unavailable on this host.")
        }
        let client = try CodexAppServerClient(executableURL: executableURL)
        let pid = client.processIdentifier
        defer { client.shutdown() }
        let provider = CodexUsageProvider(clientFactory: { client })
        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.menuBarWindow.resetAt), Date())
        let childExited = await waitUntilProcessExits(pid)
        XCTAssertTrue(childExited)
    }

    func testLiveClaudeAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let snapshot = try await ClaudeUsageProvider().fetchUsage(mode: .statusLine)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertTrue(
            snapshot.isCurrent(
                at: .now,
                maximumAge: ClaudeUsageProvider.cacheMaximumAge
            )
        )
        if let resetAt = snapshot.menuBarWindow.resetAt {
            XCTAssertGreaterThan(resetAt, Date())
        }
    }

    func testLiveClaudeOAuthAvailableWindowWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AIUSAGE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AIUSAGE_LIVE_TESTS=1 to run local account smoke tests.")
        }

        let response = try await ClaudeOAuthUsageClient().fetchUsage()
        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue((0...1).contains(snapshot.menuBarWindow.remainingFraction))
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.menuBarWindow.resetAt), Date())
    }

    private func waitUntilProcessExits(
        _ pid: Int32,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while kill(pid, 0) == 0 {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return errno == ESRCH
    }
}
