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
