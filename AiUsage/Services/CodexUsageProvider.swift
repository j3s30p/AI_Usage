import Foundation

struct CodexUsageProvider: UsageFetching {
    let provider = UsageProvider.codex

    func fetchUsage() async throws -> UsageSnapshot {
        guard let executableURL = ExecutableLocator.locate("codex") else {
            throw UsageServiceError.executableNotFound("Codex")
        }

        let client = try CodexAppServerClient(executableURL: executableURL)
        defer { client.shutdown() }

        try await client.initialize()
        let response = try await client.fetchRateLimits()
        return try Self.makeSnapshot(from: response)
    }

    static func makeSnapshot(
        from response: CodexRateLimitsResponse,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        var snapshots: [CodexRateLimitsResponse.RateLimitSnapshot] = []
        if let namedSnapshot = response.rateLimitsByLimitId?["codex"] {
            snapshots.append(namedSnapshot)
        }
        snapshots.append(response.rateLimits)

        let windows = snapshots.flatMap(\.windows)
        guard let fiveHourWindow = windows.first(where: {
            $0.windowDurationMins == 300
        }),
            let fiveHourResetTimestamp = fiveHourWindow.resetsAt
        else {
            throw UsageServiceError.currentWindowUnavailable("Codex")
        }

        let weekly = windows.first(where: {
            $0.windowDurationMins == 10_080
        }).flatMap { window -> UsageLimitWindow? in
            guard let resetTimestamp = window.resetsAt else { return nil }
            return UsageLimitWindow(
                remainingFraction: 1 - (window.usedPercent / 100),
                resetAt: Date(timeIntervalSince1970: TimeInterval(resetTimestamp))
            )
        }

        return UsageSnapshot(
            provider: .codex,
            remainingFraction: 1 - (fiveHourWindow.usedPercent / 100),
            resetAt: Date(
                timeIntervalSince1970: TimeInterval(fiveHourResetTimestamp)
            ),
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }
}
