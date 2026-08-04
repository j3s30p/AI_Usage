import Foundation

struct ClaudeDesktopUsageProvider: UsageFetching {
    let provider = UsageProvider.claude

    private let historyURL: URL

    init(historyURL: URL = Self.defaultHistoryURL) {
        self.historyURL = historyURL
    }

    func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        let historyURL = historyURL
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: historyURL, options: .mappedIfSafe)
        }.value
        try Task.checkCancellation()

        let history = try JSONDecoder().decode(History.self, from: data)
        guard history.version == 2,
              let sample = history.samples.last,
              sample.t.isFinite,
              sample.usage.fiveHour != nil || sample.usage.sevenDay != nil
        else {
            throw UsageServiceError.invalidResponse("Claude Desktop")
        }

        return UsageSnapshot(
            provider: .claude,
            fiveHour: sample.usage.fiveHour.map(Self.makeWindow),
            weekly: sample.usage.sevenDay.map(Self.makeWindow),
            fetchedAt: Date(timeIntervalSince1970: sample.t / 1_000)
        )
    }

    private static let defaultHistoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        .appendingPathComponent("plan-usage-history.json", isDirectory: false)

    private static func makeWindow(usedPercentage: Double) -> UsageLimitWindow {
        UsageLimitWindow(
            remainingFraction: ClaudeUsageProvider.remainingFraction(for: usedPercentage),
            resetAt: nil
        )
    }

    private struct History: Decodable {
        let version: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let t: TimeInterval
        let usage: Usage

        enum CodingKeys: String, CodingKey {
            case t
            case usage = "u"
        }
    }

    private struct Usage: Decodable {
        let fiveHour: Double?
        let sevenDay: Double?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "fh"
            case sevenDay = "sd"
        }
    }
}
