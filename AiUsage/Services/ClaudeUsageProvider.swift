import Foundation

struct ClaudeUsageProvider: UsageFetching {
    typealias OAuthFetcher = @Sendable () async throws -> ClaudeOAuthUsageResponse
    typealias CLIFetcher = @Sendable () async throws -> ClaudeCLIUsageSnapshot

    let provider = UsageProvider.claude
    static let cacheMaximumAge: TimeInterval = 15 * 60

    private let cacheURL: URL
    private let oauthFetcher: OAuthFetcher
    private let cliFetcher: CLIFetcher
    private let now: @Sendable () -> Date

    init(
        cacheURL: URL = Self.defaultCacheURL,
        oauthFetcher: OAuthFetcher? = nil,
        cliFetcher: CLIFetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        if let oauthFetcher {
            self.oauthFetcher = oauthFetcher
        } else {
            let client = ClaudeOAuthUsageClient()
            self.oauthFetcher = { try await client.fetchUsage() }
        }
        if let cliFetcher {
            self.cliFetcher = cliFetcher
        } else {
            let probe = ClaudeCLIUsageProbe()
            self.cliFetcher = { try await probe.fetchUsage() }
        }
        self.now = now
    }

    func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        do {
            let response = try await oauthFetcher()
            return try Self.makeSnapshot(from: response, fetchedAt: now())
        } catch {
            try Self.rethrowCancellation(error)
        }

        try Task.checkCancellation()
        do {
            let response = try await cliFetcher()
            return try Self.makeSnapshot(from: response, fetchedAt: now())
        } catch {
            try Self.rethrowCancellation(error)
        }

        try Task.checkCancellation()
        do {
            return try await fetchCachedUsage()
        } catch {
            try Self.rethrowCancellation(error)
            throw UsageServiceError.allSourcesUnavailable("Claude")
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
        guard let fiveHour = response.fiveHour,
              let resetAt = fiveHour.resetsAt,
              fiveHour.utilization.isFinite
        else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        let weekly = response.sevenDay.flatMap { window -> UsageLimitWindow? in
            guard window.utilization.isFinite, let resetAt = window.resetsAt else {
                return nil
            }
            return makeWindow(
                usedPercentage: window.utilization,
                resetAt: resetAt
            )
        }
        return UsageSnapshot(
            provider: .claude,
            remainingFraction: remainingFraction(for: fiveHour.utilization),
            resetAt: resetAt,
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    static func makeSnapshot(
        from response: ClaudeCLIUsageSnapshot,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        guard response.sessionUsedPercentage.isFinite,
              let resetAt = resetDate(
                  from: response.sessionResetDescription,
                  relativeTo: fetchedAt
              )
        else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        let weekly: UsageLimitWindow?
        if let usedPercentage = response.weeklyUsedPercentage,
           usedPercentage.isFinite,
           let weeklyResetAt = resetDate(
               from: response.weeklyResetDescription,
               relativeTo: fetchedAt
           ) {
            weekly = makeWindow(
                usedPercentage: usedPercentage,
                resetAt: weeklyResetAt
            )
        } else {
            weekly = nil
        }
        return UsageSnapshot(
            provider: .claude,
            remainingFraction: remainingFraction(
                for: response.sessionUsedPercentage
            ),
            resetAt: resetAt,
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

        guard let currentWindow = response.rateLimits?.fiveHour,
              let fiveHour = makeWindow(from: currentWindow)
        else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        let weekly = response.rateLimits?.sevenDay.flatMap(makeWindow)
        return UsageSnapshot(
            provider: .claude,
            remainingFraction: fiveHour.remainingFraction,
            resetAt: fiveHour.resetAt,
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    private static let defaultCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("usage-cache.json", isDirectory: false)

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

    private static func remainingFraction(for usedPercentage: Double) -> Double {
        let utilization = min(max(usedPercentage, 0), 100)
        return 1 - (utilization / 100)
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
    }

    private static func resetDate(
        from description: String?,
        relativeTo now: Date
    ) -> Date? {
        guard var text = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        text = text.replacingOccurrences(
            of: #"(?i)^resets?:?\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: " at ",
            with: " ",
            options: .caseInsensitive
        )

        let timeZone: TimeZone
        if let range = text.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
            let identifier = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            guard let parsedTimeZone = TimeZone(identifier: identifier) else {
                return nil
            }
            timeZone = parsedTimeZone
            text.removeSubrange(range)
        } else {
            timeZone = .current
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.defaultDate = Date(timeIntervalSince1970: 946_684_800)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dateFormats = [
            "MMM d, h:mma", "MMM d, h:mm a", "MMM d h:mma", "MMM d h:mm a",
            "MMM d, ha", "MMM d, h a", "MMM d ha", "MMM d h a",
        ]
        for format in dateFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            let components = calendar.dateComponents(
                [.month, .day, .hour, .minute],
                from: parsed
            )
            let currentYear = calendar.component(.year, from: now)
            for yearOffset in 0...8 {
                var candidateComponents = components
                candidateComponents.year = currentYear + yearOffset
                candidateComponents.second = 0
                if let candidate = calendar.date(from: candidateComponents), candidate > now {
                    return candidate
                }
            }
            return nil
        }

        let timeFormats = ["h:mma", "h:mm a", "ha", "h a", "HH:mm", "H:mm"]
        for format in timeFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.hour = time.hour
            day.minute = time.minute
            day.second = 0
            guard var candidate = calendar.date(from: day) else { return nil }
            if candidate <= now {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return nil
                }
                candidate = nextDay
            }
            return candidate
        }
        return nil
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
