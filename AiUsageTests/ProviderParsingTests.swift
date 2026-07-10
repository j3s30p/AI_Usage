import Foundation
import XCTest
@testable import AiUsage

final class ProviderParsingTests: XCTestCase {
    func testCodexParsesFiveHourAndWeeklyWindows() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 8,
                  "windowDurationMins": 10080,
                  "resetsAt": 1784250938
                },
                "secondary": {
                  "usedPercent": 52,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                }
              },
              "rateLimitsByLimitId": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.remainingFraction, 0.48, accuracy: 0.0001)
        XCTAssertEqual(snapshot.remainingPercentage, 48)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_783_664_138)
        XCTAssertEqual(snapshot.weekly?.remainingFraction ?? -1, 0.92, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 92)
        XCTAssertEqual(snapshot.weekly?.resetAt.timeIntervalSince1970, 1_784_250_938)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testCodexRejectsWeeklyOnlyResponse() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 8,
                  "windowDurationMins": 10080,
                  "resetsAt": 1784250938
                },
                "secondary": null
              },
              "rateLimitsByLimitId": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        XCTAssertThrowsError(try CodexUsageProvider.makeSnapshot(from: response))
    }

    func testCodexAllowsMissingWeeklyWindow() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 52,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                },
                "secondary": null
              },
              "rateLimitsByLimitId": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 48)
        XCTAssertNil(snapshot.weekly)
    }

    func testClaudeParsesStatusLineFiveHourAndWeeklyWindows() throws {
        let data = Data(
            """
            {
              "captured_at": 200,
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 49.0,
                  "resets_at": 1783664138
                },
                "seven_day": {
                  "used_percentage": 5.0,
                  "resets_at": 1784250938
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let snapshot = try ClaudeUsageProvider.makeSnapshot(
            from: response,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.remainingFraction, 0.51, accuracy: 0.0001)
        XCTAssertEqual(snapshot.remainingPercentage, 51)
        XCTAssertEqual(snapshot.weekly?.remainingFraction ?? -1, 0.95, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 95)
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, 200)
    }

    func testClaudeClampsUnexpectedUtilization() throws {
        let response = ClaudeUsageResponse(
            rateLimits: .init(
                fiveHour: .init(
                    usedPercentage: 140,
                    resetsAt: 1_783_664_138
                )
            )
        )

        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)
        XCTAssertEqual(snapshot.remainingFraction, 0)
        XCTAssertEqual(snapshot.remainingPercentage, 0)
        XCTAssertNil(snapshot.weekly)
    }

    func testClaudeIgnoresWeeklyWindowWithInvalidResetTimestamp() throws {
        let response = ClaudeUsageResponse(
            rateLimits: .init(
                fiveHour: .init(
                    usedPercentage: 49,
                    resetsAt: 1_783_664_138
                ),
                sevenDay: .init(
                    usedPercentage: 5,
                    resetsAt: .nan
                )
            )
        )

        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 51)
        XCTAssertNil(snapshot.weekly)
    }

    func testClaudeDecodingIgnoresMalformedWeeklyWindow() throws {
        let data = Data(
            """
            {
              "captured_at": 200,
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 49.0,
                  "resets_at": 1783664138
                },
                "seven_day": {
                  "used_percentage": "unavailable",
                  "resets_at": 1784250938
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 51)
        XCTAssertNil(snapshot.weekly)
    }

    func testClaudeProviderReadsSanitizedStatusLineCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("usage-cache.json")
        let capturedAt = Date.now.timeIntervalSince1970
        let resetAt = capturedAt + 3_600
        let weeklyResetAt = capturedAt + 86_400
        let data = Data(
            """
            {
              "captured_at": \(capturedAt),
              "status": "ready",
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 23.5,
                  "resets_at": \(resetAt)
                },
                "seven_day": {
                  "used_percentage": 41.2,
                  "resets_at": \(weeklyResetAt)
                }
              }
            }
            """.utf8
        )
        try data.write(to: cacheURL, options: .atomic)

        let snapshot = try await ClaudeUsageProvider(cacheURL: cacheURL).fetchUsage()

        XCTAssertEqual(snapshot.remainingFraction, 0.765, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekly?.remainingFraction ?? -1, 0.588, accuracy: 0.0001)
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, capturedAt, accuracy: 0.001)
    }

    func testClaudeDistinguishesWaitingAndUnsupportedStatusLineCaches() {
        XCTAssertThrowsError(
            try ClaudeUsageProvider.makeSnapshot(
                from: ClaudeUsageResponse(
                    status: "waiting_for_first_response",
                    rateLimits: nil
                )
            )
        ) { error in
            guard case UsageServiceError.usageCacheWaiting = error else {
                return XCTFail("Expected waiting cache error, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try ClaudeUsageProvider.makeSnapshot(
                from: ClaudeUsageResponse(
                    status: "unsupported_account",
                    rateLimits: nil
                )
            )
        ) { error in
            guard case UsageServiceError.usageLimitsUnavailable = error else {
                return XCTFail("Expected unsupported account error, got \(error)")
            }
        }
    }

    func testClaudeProviderPreservesStaleAndExpiredCachesForPopover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date.now.timeIntervalSince1970
        let cacheURL = directory.appendingPathComponent("usage-cache.json")
        let stale = Data(
            """
            {
              "captured_at": \(now - ClaudeUsageProvider.cacheMaximumAge - 1),
              "status": "ready",
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 20,
                  "resets_at": \(now + 3_600)
                }
              }
            }
            """.utf8
        )
        try stale.write(to: cacheURL, options: .atomic)

        let staleSnapshot = try await ClaudeUsageProvider(cacheURL: cacheURL).fetchUsage()
        XCTAssertFalse(
            staleSnapshot.isCurrent(
                at: Date(timeIntervalSince1970: now),
                maximumAge: ClaudeUsageProvider.cacheMaximumAge
            )
        )

        let expired = Data(
            """
            {
              "captured_at": \(now),
              "status": "ready",
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 20,
                  "resets_at": \(now - 1)
                }
              }
            }
            """.utf8
        )
        try expired.write(to: cacheURL, options: .atomic)

        let expiredSnapshot = try await ClaudeUsageProvider(cacheURL: cacheURL).fetchUsage()
        XCTAssertFalse(
            expiredSnapshot.isCurrent(
                at: Date(timeIntervalSince1970: now),
                maximumAge: ClaudeUsageProvider.cacheMaximumAge
            )
        )
    }
}
