import Foundation

struct UsageSnapshot: Sendable, Codable, Equatable {
    let provider: UsageProvider
    let remainingFraction: Double
    let resetAt: Date
    let fetchedAt: Date

    init(
        provider: UsageProvider,
        remainingFraction: Double,
        resetAt: Date,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.remainingFraction = remainingFraction.isFinite
            ? min(max(remainingFraction, 0), 1)
            : 0
        self.resetAt = resetAt
        self.fetchedAt = fetchedAt
    }

    var remainingPercentage: Int {
        Int((remainingFraction * 100).rounded())
    }
}
