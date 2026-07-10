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

        guard let window = snapshots
            .lazy
            .flatMap(\.windows)
            .first(where: { $0.windowDurationMins == 300 }),
            let resetTimestamp = window.resetsAt
        else {
            throw UsageServiceError.currentWindowUnavailable("Codex")
        }

        let remainingFraction = 1 - (window.usedPercent / 100)
        return UsageSnapshot(
            provider: .codex,
            remainingFraction: remainingFraction,
            resetAt: Date(timeIntervalSince1970: TimeInterval(resetTimestamp)),
            fetchedAt: fetchedAt
        )
    }
}
