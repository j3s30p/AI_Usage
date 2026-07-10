import SwiftUI

struct ProviderUsageRow: View {
    let provider: UsageProvider
    let state: ProviderLoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)

                Text("현재 5시간")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("새로 고치는 중")
                }
            }

            if let snapshot = state.snapshot {
                HStack(spacing: 10) {
                    RemainingRing(
                        remainingFraction: snapshot.remainingFraction,
                        size: 30,
                        lineWidth: 3
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(snapshot.remainingPercentage)% 남음")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("초기화 \(snapshot.resetAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
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
}
