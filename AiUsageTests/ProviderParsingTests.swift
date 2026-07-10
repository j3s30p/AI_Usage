import Foundation
import XCTest
@testable import AiUsage

final class ProviderParsingTests: XCTestCase {
    func testCodexSelectsFiveHourWindowEvenWhenItIsSecondary() throws {
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

    func testClaudeParsesOnlyCurrentFiveHourWindow() throws {
        let data = Data(
            """
            {
              "five_hour": {
                "utilization": 49.0,
                "resets_at": "2026-07-10T05:59:59.764470+00:00"
              },
              "seven_day": {
                "utilization": 5.0,
                "resets_at": "2026-07-14T00:00:00+00:00"
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
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, 200)
    }

    func testClaudeClampsUnexpectedUtilization() throws {
        let response = ClaudeUsageResponse(
            fiveHour: .init(
                utilization: 140,
                resetsAt: "2026-07-10T05:59:59Z"
            )
        )

        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)
        XCTAssertEqual(snapshot.remainingFraction, 0)
        XCTAssertEqual(snapshot.remainingPercentage, 0)
    }
}
