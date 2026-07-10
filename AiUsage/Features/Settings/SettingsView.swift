import Foundation
import SwiftUI

struct SettingsView: View {
    typealias ClaudeKeychainConnectionAction = @MainActor @Sendable () async throws -> Void

    @Bindable var preferences: AppPreferences
    private let onConnectClaudeKeychain: ClaudeKeychainConnectionAction

    @State private var isConnectingClaudeKeychain = false
    @State private var claudeKeychainConnectionMessage: String?
    @State private var claudeKeychainConnectionSucceeded = false

    init(preferences: AppPreferences) {
        self.init(
            preferences: preferences,
            onConnectClaudeKeychain: {
                throw NSError(
                    domain: "AiUsage.ClaudeKeychainConnection",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Keychain 연결 기능이 구성되지 않았습니다."
                    ]
                )
            }
        )
    }

    init(
        preferences: AppPreferences,
        onConnectClaudeKeychain: @escaping ClaudeKeychainConnectionAction
    ) {
        self.preferences = preferences
        self.onConnectClaudeKeychain = onConnectClaudeKeychain
    }

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

                if preferences.showClaude {
                    Picker("Claude 조회 방식", selection: $preferences.claudeUsageMode) {
                        ForEach(ClaudeUsageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    claudeUsageModeDescription

                    if preferences.claudeUsageMode == .oauth {
                        claudeKeychainConnectionControls
                    }
                }
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

    @ViewBuilder
    private var claudeUsageModeDescription: some View {
        switch preferences.claudeUsageMode {
        case .statusLine:
            Label(
                "Claude Code가 남긴 statusLine 캐시만 읽습니다. Keychain에 접근하거나 로그인 절차를 시작하지 않으며, Claude Code를 사용한 뒤 캐시가 갱신됩니다.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .oauth:
            Label(
                "백그라운드에서는 승인 창 없이 OAuth 사용량을 조회하고, Keychain을 조용히 읽을 수 없거나 조회가 실패하면 statusLine 캐시로 넘어갑니다. 비공개 API라 중단될 수 있으며 ad-hoc 빌드는 서명이 바뀌면 승인을 다시 요구할 수 있습니다. 아래 버튼을 눌렀을 때만 Keychain 승인 창이 한 번 표시될 수 있습니다.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

        case .cliUsage:
            Label(
                "먼저 claude auth status로 로그인 상태를 확인합니다. 로그인되어 있을 때만 /usage를 실행하며 AiUsage가 자동 로그인이나 브라우저를 요청하지는 않습니다. 다만 외부 Claude CLI가 자체적으로 표시하는 Keychain 잠금 해제·승인 UI까지 AiUsage가 차단할 수는 없습니다. 조회가 실패하면 statusLine 캐시로 넘어갑니다.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var claudeKeychainConnectionControls: some View {
        Button {
            connectClaudeKeychain()
        } label: {
            if isConnectingClaudeKeychain {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Keychain 연결 중…")
                }
            } else {
                Label("Keychain 연결", systemImage: "key")
            }
        }
        .disabled(isConnectingClaudeKeychain)
        .accessibilityLabel(
            isConnectingClaudeKeychain
                ? "Claude Keychain 연결 중"
                : "Claude Keychain 연결"
        )
        .accessibilityHint(
            "사용자가 누를 때 한 번만 macOS Keychain 접근 승인을 요청합니다."
        )

        if let claudeKeychainConnectionMessage {
            Label(
                claudeKeychainConnectionMessage,
                systemImage: claudeKeychainConnectionSucceeded
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(
                claudeKeychainConnectionSucceeded ? .green : .red
            )
            .accessibilityLabel(
                "Claude Keychain 연결 결과: \(claudeKeychainConnectionMessage)"
            )
        }
    }

    private func connectClaudeKeychain() {
        guard !isConnectingClaudeKeychain else { return }
        isConnectingClaudeKeychain = true
        claudeKeychainConnectionMessage = nil
        claudeKeychainConnectionSucceeded = false

        Task { @MainActor in
            defer { isConnectingClaudeKeychain = false }
            do {
                try await onConnectClaudeKeychain()
                claudeKeychainConnectionSucceeded = true
                claudeKeychainConnectionMessage = "Keychain 연결을 확인했습니다."
            } catch {
                claudeKeychainConnectionMessage =
                    "Keychain 연결에 실패했습니다. Claude Code 로그인 상태와 앱 서명을 확인해 주세요."
            }
        }
    }
}
