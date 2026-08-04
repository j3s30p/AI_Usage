import Foundation

struct ClaudeUsageProvider: UsageFetching {
    typealias OAuthFetcher = @Sendable () async throws -> ClaudeOAuthUsageResponse
    typealias DesktopFetcher = @Sendable () async throws -> UsageSnapshot

    let provider = UsageProvider.claude
    static let cacheMaximumAge: TimeInterval = 15 * 60

    private let cacheURL: URL
    private let oauthFetcher: OAuthFetcher
    private let desktopFetcher: DesktopFetcher
    private let now: @Sendable () -> Date

    init(
        cacheURL: URL = Self.defaultCacheURL,
        oauthFetcher: OAuthFetcher? = nil,
        desktopFetcher: DesktopFetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        if let oauthFetcher {
            self.oauthFetcher = oauthFetcher
        } else {
            let client = ClaudeOAuthUsageClient()
            self.oauthFetcher = { try await client.fetchUsage() }
        }
        if let desktopFetcher {
            self.desktopFetcher = desktopFetcher
        } else {
            let provider = ClaudeDesktopUsageProvider()
            self.desktopFetcher = { try await provider.fetchUsage() }
        }
        self.now = now
    }

    func fetchUsage() async throws -> UsageSnapshot {
        try await fetchUsage(mode: .statusLine)
    }

    func fetchUsage(mode: ClaudeUsageMode) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        switch mode {
        case .statusLine:
            return try await fetchStatusLineOrDesktop()
        case .oauth:
            return try await fetchOAuthOrFallbackUsage()
        }
    }

    private func fetchOAuthOrFallbackUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        do {
            let response = try await oauthFetcher()
            return try Self.makeSnapshot(from: response, fetchedAt: now())
        } catch {
            try Self.rethrowCancellation(error)
        }

        return try await fetchStatusLineOrDesktop(
            unavailableError: .claudeOAuthAndCacheUnavailable
        )
    }

    private func fetchStatusLineOrDesktop(
        unavailableError: UsageServiceError? = nil
    ) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        do {
            let cached = try await fetchCachedUsage()
            let currentDate = now()
            guard !cached.isCurrent(
                at: currentDate,
                maximumAge: Self.cacheMaximumAge
            ) else { return cached }

            do {
                let desktop = try await desktopFetcher()
                try Task.checkCancellation()
                if desktop.isCurrent(
                    at: currentDate,
                    maximumAge: Self.cacheMaximumAge
                ) || desktop.fetchedAt > cached.fetchedAt {
                    return desktop
                }
            } catch {
                try Self.rethrowCancellation(error)
            }
            return cached
        } catch let cacheError {
            try Self.rethrowCancellation(cacheError)
            do {
                let desktop = try await desktopFetcher()
                try Task.checkCancellation()
                return desktop
            } catch {
                try Self.rethrowCancellation(error)
                throw unavailableError ?? cacheError
            }
        }
    }

    private func fetchCachedUsage() async throws -> UsageSnapshot {
        let cacheURL = cacheURL
        let cached = try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: cacheURL.path) else {
                throw UsageServiceError.usageCacheUnavailable("Claude")
            }

            let data: Data
            do {
                data = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
            } catch {
                throw UsageServiceError.usageCacheUnavailable("Claude")
            }

            let modifiedAt = try? cacheURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return CachedUsage(data: data, modifiedAt: modifiedAt)
        }.value

        let response: ClaudeUsageResponse
        do {
            response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: cached.data)
        } catch {
            throw UsageServiceError.invalidResponse("Claude")
        }

        let capturedAt = response.capturedAt
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            ?? cached.modifiedAt
            ?? .now
        return try Self.makeSnapshot(from: response, fetchedAt: capturedAt)
    }

    static func makeSnapshot(
        from response: ClaudeOAuthUsageResponse,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        let fiveHour = response.fiveHour.flatMap(makeWindow)
        let weekly = response.sevenDay.flatMap(makeWindow)
        guard fiveHour != nil || weekly != nil else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        return UsageSnapshot(
            provider: .claude,
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    static func makeSnapshot(
        from response: ClaudeUsageResponse,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        if response.rateLimits == nil {
            switch response.status {
            case "waiting_for_first_response":
                throw UsageServiceError.usageCacheWaiting
            case "unsupported_account":
                throw UsageServiceError.usageLimitsUnavailable
            default:
                break
            }
        }

        let fiveHour = response.rateLimits?.fiveHour.flatMap(makeWindow)
        let weekly = response.rateLimits?.sevenDay.flatMap(makeWindow)
        guard fiveHour != nil || weekly != nil else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        return UsageSnapshot(
            provider: .claude,
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    private static let defaultCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("usage-cache.json", isDirectory: false)

    private static func makeWindow(
        from window: ClaudeOAuthUsageWindow
    ) -> UsageLimitWindow? {
        guard window.utilization.isFinite, let resetAt = window.resetsAt else {
            return nil
        }
        return makeWindow(
            usedPercentage: window.utilization,
            resetAt: resetAt
        )
    }

    private static func makeWindow(
        from window: ClaudeUsageResponse.Window
    ) -> UsageLimitWindow? {
        guard window.usedPercentage.isFinite,
              window.resetsAt.isFinite
        else { return nil }

        return makeWindow(
            usedPercentage: window.usedPercentage,
            resetAt: Date(timeIntervalSince1970: window.resetsAt)
        )
    }

    private static func makeWindow(
        usedPercentage: Double,
        resetAt: Date
    ) -> UsageLimitWindow {
        UsageLimitWindow(
            remainingFraction: remainingFraction(for: usedPercentage),
            resetAt: resetAt
        )
    }

    static func remainingFraction(for usedPercentage: Double) -> Double {
        let utilization = min(max(usedPercentage, 0), 100)
        return 1 - (utilization / 100)
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
    }

    private struct CachedUsage: Sendable {
        let data: Data
        let modifiedAt: Date?
    }
}

struct ClaudeUsageResponse: Decodable, Sendable {
    let capturedAt: TimeInterval?
    let status: String?
    let rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case status
        case rateLimits = "rate_limits"
    }

    init(
        capturedAt: TimeInterval? = nil,
        status: String? = nil,
        rateLimits: RateLimits?
    ) {
        self.capturedAt = capturedAt
        self.status = status
        self.rateLimits = rateLimits
    }

    struct RateLimits: Decodable, Sendable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        init(fiveHour: Window?, sevenDay: Window? = nil) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
        }
    }

    struct Window: Decodable, Sendable {
        let usedPercentage: Double
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }
}
