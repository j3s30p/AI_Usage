import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("메뉴바에 표시") {
                Toggle("Codex", isOn: $preferences.showCodex)
                Toggle("Claude", isOn: $preferences.showClaude)
                Toggle("남은 퍼센트 표시", isOn: $preferences.showPercentage)
            }

            Section("메뉴바 스타일") {
                Picker("서비스 표시 방식", selection: $preferences.providerDisplayMode) {
                    ForEach(ProviderDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("사용량 갱신") {
                Picker("자동 갱신 주기", selection: $preferences.refreshInterval) {
                    ForEach(UsageRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                Text("Claude는 OAuth, CLI, statusLine 순으로 조회합니다. 자동 갱신은 키체인 창을 띄우지 않으며 OAuth를 조용히 읽을 수 없으면 CLI로 넘어갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preferences.enabledProviders.isEmpty {
                Label(
                    "두 서비스를 모두 끄면 메뉴바에는 AiUsage 아이콘만 표시됩니다.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
