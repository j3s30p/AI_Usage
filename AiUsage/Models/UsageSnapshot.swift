import Foundation

struct UsageSnapshot: Sendable, Codable, Equatable {
    let provider: UsageProvider
    let fiveHour: UsageLimitWindow
    let weekly: UsageLimitWindow?
    let fetchedAt: Date

    init(
        provider: UsageProvider,
        remainingFraction: Double,
        resetAt: Date,
        weekly: UsageLimitWindow? = nil,
        fetchedAt: Date
    ) {
        self.provider = provider
        fiveHour = UsageLimitWindow(
            remainingFraction: remainingFraction,
            resetAt: resetAt
        )
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    var remainingFraction: Double {
        fiveHour.remainingFraction
    }

    var resetAt: Date {
        fiveHour.resetAt
    }

    var remainingPercentage: Int {
        fiveHour.remainingPercentage
    }

    func isCurrent(at date: Date, maximumAge: TimeInterval) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return resetAt > date && age >= 0 && age <= maximumAge
    }
}
