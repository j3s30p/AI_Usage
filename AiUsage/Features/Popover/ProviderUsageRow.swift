import SwiftUI

struct ProviderUsageRow: View {
    let provider: UsageProvider
    let state: ProviderLoadState
    let maximumSnapshotAge: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)

                if let snapshot = state.snapshot {
                    let isStale = !snapshot.isCurrent(
                        at: .now,
                        maximumAge: maximumSnapshotAge
                    )
                    HStack(spacing: 3) {
                        if isStale {
                            Text("업데이트 지연 ·")
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
                        "\(provider.displayName) 사용량 \(isStale ? "업데이트 지연, " : "")\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) 기준"
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
                    if let fiveHour = snapshot.fiveHour {
                        usageWindowRow(title: "5시간", window: fiveHour)
                    } else {
                        unavailableWindowRow(title: "5시간")
                    }

                    if let weekly = snapshot.weekly {
                        usageWindowRow(title: "주간", window: weekly)
                    } else {
                        unavailableWindowRow(title: "주간")
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

    private func unavailableWindowRow(title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            Text("제공되지 않음")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), 제공되지 않음")
    }
}
