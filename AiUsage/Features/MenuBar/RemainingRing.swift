import SwiftUI

struct RemainingRing: View {
    let remainingFraction: Double?
    var usesUsageColors = false
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.4

    var body: some View {
        ZStack {
            if let remainingFraction {
                let remaining = Self.normalizedRemaining(remainingFraction)
                let color = usesUsageColors
                    ? UsageRingColor.color(for: remaining).swiftUIColor
                    : Color.primary
                if Self.isDisplayedAsZero(remaining) {
                    Circle()
                        .trim(from: 0, to: Self.zeroRemainingDisplayFraction)
                        .stroke(
                            usesUsageColors ? color : .red,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                } else if remaining >= 1 {
                    Circle()
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: lineWidth)
                        )
                } else if remaining > 0 {
                    Circle()
                        .trim(from: Self.trimStart(forRemaining: remaining), to: 1)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            } else {
                Circle()
                    .stroke(
                        .secondary.opacity(0.75),
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            dash: [1.2, 2]
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    nonisolated static func normalizedRemaining(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    nonisolated static func trimStart(forRemaining value: Double) -> Double {
        1 - normalizedRemaining(value)
    }

    nonisolated static func isDisplayedAsZero(_ value: Double) -> Bool {
        Int((normalizedRemaining(value) * 100).rounded()) == 0
    }

    nonisolated static let zeroRemainingDisplayFraction = 1.0 / 360.0
}

private extension UsageRingColor {
    var swiftUIColor: Color {
        switch self {
        case .critical: .red
        case .warning: .yellow
        case .healthy: .green
        }
    }
}
