import Foundation

struct ClaudeUsageProvider: UsageFetching {
    let provider = UsageProvider.claude
    static let cacheMaximumAge: TimeInterval = 15 * 60

    private let cacheURL: URL

    init(cacheURL: URL = Self.defaultCacheURL) {
        self.cacheURL = cacheURL
    }

    func fetchUsage() async throws -> UsageSnapshot {
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

        let utilization = min(max(window.usedPercentage, 0), 100)
        return UsageLimitWindow(
            remainingFraction: 1 - (utilization / 100),
            resetAt: Date(timeIntervalSince1970: window.resetsAt)
        )
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
