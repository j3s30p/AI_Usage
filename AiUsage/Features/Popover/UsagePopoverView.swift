import AppKit
import SwiftUI

struct UsagePopoverView: View {
    let model: AppModel
    let preferences: AppPreferences

    var body: some View {
        let providers = UsageProvider.allCases.filter {
            preferences.enabledProviders.contains($0)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AiUsage")
                    .font(.headline)
                Spacer()
                Button("새로 고침", systemImage: "arrow.clockwise") {
                    Task {
                        await model.refresh(
                            providers: preferences.enabledProviders,
                            claudeUsageMode: preferences.claudeUsageMode
                        )
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(providers.isEmpty || model.isRefreshing)
            }

            if providers.isEmpty {
                ContentUnavailableView(
                    "표시할 서비스가 없습니다",
                    systemImage: "chart.pie",
                    description: Text("설정에서 Codex 또는 Claude를 선택해 주세요.")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(providers) { provider in
                            ProviderUsageRow(
                                provider: provider,
                                state: model.state(for: provider),
                                maximumSnapshotAge: preferences.refreshInterval
                                    .maximumExpectedSnapshotAge
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()

            HStack {
                SettingsLink {
                    Label("설정", systemImage: "gear")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 340, height: 390)
    }
}
