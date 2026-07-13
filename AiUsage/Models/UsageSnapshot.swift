import Foundation

struct UsageSnapshot: Sendable, Codable, Equatable {
    let provider: UsageProvider
    let fiveHour: UsageLimitWindow?
    let weekly: UsageLimitWindow?
    let fetchedAt: Date

    init(
        provider: UsageProvider,
        remainingFraction: Double,
        resetAt: Date,
        weekly: UsageLimitWindow? = nil,
        fetchedAt: Date
    ) {
        self.init(
            provider: provider,
            fiveHour: UsageLimitWindow(
                remainingFraction: remainingFraction,
                resetAt: resetAt
            ),
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    init(
        provider: UsageProvider,
        fiveHour: UsageLimitWindow?,
        weekly: UsageLimitWindow?,
        fetchedAt: Date
    ) {
        precondition(fiveHour != nil || weekly != nil)
        self.provider = provider
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    var menuBarWindow: UsageLimitWindow {
        if let fiveHour {
            return fiveHour
        }
        guard let weekly else {
            preconditionFailure("UsageSnapshot requires at least one usage window.")
        }
        return weekly
    }

    var remainingFraction: Double {
        menuBarWindow.remainingFraction
    }

    var resetAt: Date {
        menuBarWindow.resetAt
    }

    var remainingPercentage: Int {
        menuBarWindow.remainingPercentage
    }

    func isCurrent(at date: Date, maximumAge: TimeInterval) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return resetAt > date && age >= 0 && age <= maximumAge
    }
}
