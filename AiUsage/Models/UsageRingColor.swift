enum UsageRingColor: Equatable, Sendable {
    case critical
    case warning
    case healthy

    nonisolated static func color(for remainingFraction: Double) -> Self {
        let percentage = Int(
            (RemainingRing.normalizedRemaining(remainingFraction) * 100).rounded()
        )
        if percentage <= 5 { return .critical }
        if percentage <= 30 { return .warning }
        return .healthy
    }
}
