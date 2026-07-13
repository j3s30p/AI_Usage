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

    func testCodexParsesCurrentWeeklyOnlyMultiLimitResponse() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1784506240
                },
                "secondary": null
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 3,
                    "windowDurationMins": 10080,
                    "resetsAt": 1784506240
                  },
                  "secondary": null
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1784508713
                  },
                  "secondary": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 97)
        XCTAssertEqual(snapshot.menuBarWindow.remainingPercentage, 97)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_784_506_240)
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

    func testCodexUsesNamedDefaultLimitInsteadOfTopLevelSparkLimit() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex_bengalfox",
                "primary": {
                  "usedPercent": 0,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664000
                },
                "secondary": {
                  "usedPercent": 0,
                  "windowDurationMins": 10080,
                  "resetsAt": 1784250800
                }
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 37,
                    "windowDurationMins": 300,
                    "resetsAt": 1783664138
                  },
                  "secondary": {
                    "usedPercent": 12,
                    "windowDurationMins": 10080,
                    "resetsAt": 1784250938
                  }
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1783664000
                  },
                  "secondary": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 63)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 88)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_783_664_138)
    }

    func testCodexRejectsTopLevelSparkWhenNamedDefaultLimitIsTemporarilyMissing() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex_bengalfox",
                "primary": {
                  "usedPercent": 0,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                },
                "secondary": {
                  "usedPercent": 0,
                  "windowDurationMins": 10080,
                  "resetsAt": 1784250938
                }
              },
              "rateLimitsByLimitId": {
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1783664138
                  },
                  "secondary": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        XCTAssertEqual(response.rateLimits.limitId, "codex_bengalfox")

        XCTAssertThrowsError(try CodexUsageProvider.makeSnapshot(from: response)) { error in
            guard case UsageServiceError.currentWindowUnavailable("Codex") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCodexUsesExplicitTopLevelDefaultWhenMultiLimitMapOmitsItsKey() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 31,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                },
                "secondary": null
              },
              "rateLimitsByLimitId": {
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1783664000
                  },
                  "secondary": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 69)
    }

    func testCodexKeepsTopLevelFallbackForEmptyLegacyLimitMap() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 25,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                },
                "secondary": null
              },
              "rateLimitsByLimitId": {}
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 75)
    }

    func testCodexAllowsRealNamedDefaultLimitAtZeroPercentUsed() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 0,
                  "windowDurationMins": 300,
                  "resetsAt": 1783664138
                },
                "secondary": null
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1783664138
                  },
                  "secondary": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        let snapshot = try CodexUsageProvider.makeSnapshot(from: response)

        XCTAssertEqual(snapshot.remainingPercentage, 100)
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

    func testClaudeParsesStatusLineWeeklyOnlyWindow() throws {
        let response = ClaudeUsageResponse(
            rateLimits: .init(
                fiveHour: nil,
                sevenDay: .init(
                    usedPercentage: 18,
                    resetsAt: 1_784_506_240
                )
            )
        )

        let snapshot = try ClaudeUsageProvider.makeSnapshot(from: response)

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 82)
        XCTAssertEqual(snapshot.menuBarWindow.remainingPercentage, 82)
    }

    func testClaudeDefaultStatusLineModeInvokesNoActiveSource() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let cache = try makeValidClaudeCache(capturedAt: now)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let oauthCalls = ClaudeProviderCallCounter()
        let provider = ClaudeUsageProvider(
            cacheURL: cache.url,
            oauthFetcher: {
                oauthCalls.increment()
                throw InjectedClaudeProviderError("OAuth should not run")
            }
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.remainingPercentage, 75)
        XCTAssertEqual(oauthCalls.value, 0)
    }

    func testClaudeOAuthModeUsesOnlyOAuthWhenAvailable() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let oauthCalls = ClaudeProviderCallCounter()
        let provider = ClaudeUsageProvider(
            cacheURL: URL(fileURLWithPath: "/missing/status-line-cache.json"),
            oauthFetcher: {
                oauthCalls.increment()
                return ClaudeOAuthUsageResponse(
                    fiveHour: .init(
                        utilization: 25,
                        resetsAt: now.addingTimeInterval(3_600)
                    ),
                    sevenDay: .init(
                        utilization: 40,
                        resetsAt: now.addingTimeInterval(86_400)
                    )
                )
            },
            now: { now }
        )

        let snapshot = try await provider.fetchUsage(mode: .oauth)

        XCTAssertEqual(snapshot.remainingPercentage, 75)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 60)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(oauthCalls.value, 1)
    }

    func testClaudeOAuthParsesWeeklyOnlyWindow() throws {
        let resetAt = Date(timeIntervalSince1970: 1_784_506_240)
        let snapshot = try ClaudeUsageProvider.makeSnapshot(
            from: ClaudeOAuthUsageResponse(
                fiveHour: nil,
                sevenDay: .init(utilization: 18, resetsAt: resetAt)
            )
        )

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 82)
        XCTAssertEqual(snapshot.menuBarWindow.resetAt, resetAt)
    }

    func testClaudeOAuthModeFallsBackOnlyToStatusLine() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let cache = try makeValidClaudeCache(capturedAt: now)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let provider = ClaudeUsageProvider(
            cacheURL: cache.url,
            oauthFetcher: {
                throw InjectedClaudeProviderError("OAuth unavailable")
            }
        )

        let snapshot = try await provider.fetchUsage(mode: .oauth)

        XCTAssertEqual(snapshot.remainingPercentage, 75)
    }

    func testClaudeOAuthRequiresUsableWindowAndClampsUtilization() throws {
        XCTAssertThrowsError(
            try ClaudeUsageProvider.makeSnapshot(
                from: ClaudeOAuthUsageResponse(
                    fiveHour: .init(utilization: 10, resetsAt: nil),
                    sevenDay: nil
                )
            )
        ) { error in
            guard case UsageServiceError.currentWindowUnavailable("Claude") = error else {
                return XCTFail("Expected missing current-window reset error, got \(error)")
            }
        }

        let now = Date(timeIntervalSince1970: 100)
        let snapshot = try ClaudeUsageProvider.makeSnapshot(
            from: ClaudeOAuthUsageResponse(
                fiveHour: .init(
                    utilization: 140,
                    resetsAt: now.addingTimeInterval(1_000)
                ),
                sevenDay: .init(
                    utilization: -20,
                    resetsAt: now.addingTimeInterval(2_000)
                )
            ),
            fetchedAt: now
        )

        XCTAssertEqual(snapshot.remainingPercentage, 0)
        XCTAssertEqual(snapshot.weekly?.remainingPercentage, 100)
    }

    func testClaudeOAuthCancellationDoesNotFallThrough() async {
        let provider = ClaudeUsageProvider(
            cacheURL: URL(fileURLWithPath: "/missing/status-line-cache.json"),
            oauthFetcher: { throw CancellationError() }
        )

        do {
            _ = try await provider.fetchUsage(mode: .oauth)
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected: cancellation must not be replaced by cache fallback.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testClaudeOAuthFailureErrorIsUsefulAndDoesNotExposeSourceError() async {
        let oauthSecret = "oauth-secret-value"
        let oauthProvider = ClaudeUsageProvider(
            cacheURL: URL(fileURLWithPath: "/missing/status-line-cache.json"),
            oauthFetcher: { throw InjectedClaudeProviderError(oauthSecret) }
        )

        do {
            _ = try await oauthProvider.fetchUsage(mode: .oauth)
            XCTFail("Expected OAuth and cache to fail.")
        } catch let error as UsageServiceError {
            guard case .claudeOAuthAndCacheUnavailable = error else {
                return XCTFail("Expected OAuth-mode Claude error, got \(error)")
            }
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("OAuth"))
            XCTAssertTrue(description.contains("statusLine"))
            XCTAssertFalse(description.contains(oauthSecret))
        } catch {
            XCTFail("Expected UsageServiceError, got \(error)")
        }
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

        let snapshot = try await makeCacheOnlyClaudeProvider(
            cacheURL: cacheURL
        ).fetchUsage()

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

        let provider = makeCacheOnlyClaudeProvider(cacheURL: cacheURL)
        let staleSnapshot = try await provider.fetchUsage()
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

        let expiredSnapshot = try await provider.fetchUsage()
        XCTAssertFalse(
            expiredSnapshot.isCurrent(
                at: Date(timeIntervalSince1970: now),
                maximumAge: ClaudeUsageProvider.cacheMaximumAge
            )
        )
    }

    private func makeCacheOnlyClaudeProvider(cacheURL: URL) -> ClaudeUsageProvider {
        ClaudeUsageProvider(cacheURL: cacheURL)
    }

    private func makeValidClaudeCache(
        capturedAt: Date
    ) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cacheURL = directory.appendingPathComponent("usage-cache.json")
        let resetAt = capturedAt.addingTimeInterval(3_600).timeIntervalSince1970
        let weeklyResetAt = capturedAt.addingTimeInterval(86_400).timeIntervalSince1970
        let data = Data(
            """
            {
              "captured_at": \(capturedAt.timeIntervalSince1970),
              "status": "ready",
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 25,
                  "resets_at": \(resetAt)
                },
                "seven_day": {
                  "used_percentage": 40,
                  "resets_at": \(weeklyResetAt)
                }
              }
            }
            """.utf8
        )
        try data.write(to: cacheURL, options: .atomic)
        return (directory, cacheURL)
    }
}

private struct InjectedClaudeProviderError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class ClaudeProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
