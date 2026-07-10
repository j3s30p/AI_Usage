import Foundation

struct UsageLimitWindow: Sendable, Codable, Equatable {
    let remainingFraction: Double
    let resetAt: Date

    init(remainingFraction: Double, resetAt: Date) {
        self.remainingFraction = remainingFraction.isFinite
            ? min(max(remainingFraction, 0), 1)
            : 0
        self.resetAt = resetAt
    }

    var remainingPercentage: Int {
        Int((remainingFraction * 100).rounded())
    }
}
