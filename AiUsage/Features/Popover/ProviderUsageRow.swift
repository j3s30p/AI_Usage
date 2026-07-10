import SwiftUI

struct ProviderUsageRow: View {
    let provider: UsageProvider
    let state: ProviderLoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)

                if provider == .claude, let snapshot = state.snapshot {
                    let isStale = !snapshot.isCurrent(
                        at: .now,
                        maximumAge: ClaudeUsageProvider.cacheMaximumAge
                    )
                    HStack(spacing: 3) {
                        if isStale {
                            Text("오래된 캐시 ·")
                        }
                        Text(snapshot.fetchedAt, style: .relative)
                        Text("기준")
                    }
                    .font(.caption2)
                    .foregroundStyle(
                        isStale
                            ? Color.orange
                            : Color.secondary
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Claude 사용량 \(isStale ? "오래된 캐시, " : "")\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) 기준"
                    )
                }

                Spacer()

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("새로 고치는 중")
                }
            }

            if let snapshot = state.snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    usageWindowRow(title: "5시간", window: snapshot.fiveHour)

                    if let weekly = snapshot.weekly {
                        usageWindowRow(title: "주간", window: weekly)
                    } else {
                        HStack(spacing: 10) {
                            Text("주간")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .leading)

                            Text("제공되지 않음")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if !state.isLoading {
                Text("아직 사용량을 불러오지 않았습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let failure = state.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private func usageWindowRow(
        title: String,
        window: UsageLimitWindow
    ) -> some View {
        let resetText = window.resetAt.formatted(date: .abbreviated, time: .shortened)

        return HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            RemainingRing(
                remainingFraction: window.remainingFraction,
                size: 28,
                lineWidth: 3
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(window.remainingPercentage)% 남음")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("초기화 \(resetText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), \(window.remainingPercentage)% 남음, 초기화 \(resetText)"
        )
    }
}
