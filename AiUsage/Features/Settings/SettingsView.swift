import SwiftUI

struct SettingsView: View {
    typealias ClaudeOAuthAuthorizationAction =
        @MainActor @Sendable () async -> ClaudeOAuthUserInitiatedAccessResult

    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLoginController: LaunchAtLoginController
    @Bindable var statusLineModel: ClaudeStatusLineSettingsModel
    @Bindable var updateStatusModel: UpdateStatusModel

    private let onAuthorizeClaudeOAuth: ClaudeOAuthAuthorizationAction

    @State private var selectedClaudeUsageMode: ClaudeUsageMode
    @State private var isAuthorizingClaudeOAuth = false
    @State private var oauthFeedback: OAuthFeedback?
    @State private var languageChangeRequiresRestart = false
    @State private var selectedTab = 0

    init(
        preferences: AppPreferences,
        launchAtLoginController: LaunchAtLoginController,
        statusLineModel: ClaudeStatusLineSettingsModel,
        updateStatusModel: UpdateStatusModel,
        onAuthorizeClaudeOAuth: @escaping ClaudeOAuthAuthorizationAction
    ) {
        self.preferences = preferences
        self.launchAtLoginController = launchAtLoginController
        self.statusLineModel = statusLineModel
        self.updateStatusModel = updateStatusModel
        self.onAuthorizeClaudeOAuth = onAuthorizeClaudeOAuth
        _selectedClaudeUsageMode = State(
            initialValue: preferences.claudeUsageMode
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            menuBarSettings
                .tag(0)
                .tabItem {
                    Label("메뉴바", systemImage: "menubar.rectangle")
                }

            generalSettings
                .tag(1)
                .tabItem {
                    Label("일반", systemImage: "gearshape")
                }
        }
        .frame(width: 420, height: 560)
        .onChange(of: preferences.claudeUsageMode) {
            guard !isAuthorizingClaudeOAuth else { return }
            selectedClaudeUsageMode = $1
        }
        .onChange(of: preferences.appLanguage) {
            languageChangeRequiresRestart = true
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Language") {
                Picker("App Language", selection: $preferences.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                if languageChangeRequiresRestart {
                    Label(
                        "Restart AiUsage to apply the selected language.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            LaunchAtLoginSection(controller: launchAtLoginController)

            claudeUsageSettings
            ClaudeStatusLineConnectionSection(model: statusLineModel)

            Section("정보") {
                LabeledContent(
                    "현재 버전",
                    value: "v\(updateStatusModel.currentVersion)"
                )
                LabeledContent("최신 버전", value: latestVersionText)
            }
        }
        .formStyle(.grouped)
    }

    private var latestVersionText: String {
        if updateStatusModel.isChecking {
            return String(localized: "확인 중…")
        }
        guard let latestVersion = updateStatusModel.latestVersion else {
            return String(localized: "확인할 수 없음")
        }
        return "v\(latestVersion)"
    }

    private var menuBarSettings: some View {
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

                Toggle(
                    "사용량에 따라 게이지 색상 표시",
                    isOn: $preferences.colorUsageRings
                )
            }

            Section("사용량 갱신") {
                Picker("자동 갱신 주기", selection: $preferences.refreshInterval) {
                    ForEach(UsageRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
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
    }

    private var claudeUsageSettings: some View {
        Section("Claude 사용량") {
            LabeledContent("Claude 조회 방식") {
                Menu {
                    ForEach(ClaudeUsageMode.allCases) { mode in
                        Button {
                            requestClaudeUsageMode(mode)
                        } label: {
                            if selectedClaudeUsageMode == mode {
                                Label(
                                    mode.displayName,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    Text(selectedClaudeUsageMode.displayName)
                }
                .disabled(isAuthorizingClaudeOAuth)
                .accessibilityLabel("Claude 조회 방식")
                .accessibilityValue(selectedClaudeUsageMode.displayName)
            }

            claudeUsageModeDescription

            if isAuthorizingClaudeOAuth {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Claude OAuth 인증 확인 중…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let oauthFeedback {
                Label(
                    oauthFeedback.message,
                    systemImage: oauthFeedback.symbol
                )
                .font(.caption)
                .foregroundStyle(oauthFeedback.color)
            }
        }
    }

    @ViewBuilder
    private var claudeUsageModeDescription: some View {
        switch selectedClaudeUsageMode {
        case .statusLine:
            Label(
                "Claude Code가 남긴 statusLine 캐시만 읽습니다. 아래 연결 버튼을 한 번 누르면 터미널이나 설정 파일 수정 없이 자동으로 구성됩니다.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .oauth:
            Label(
                "OAuth 모드를 선택하면 먼저 Claude Code 인증 파일을 확인하고, 사용할 수 없을 때만 Keychain 승인을 요청합니다. 이후 백그라운드 조회는 팝업 없이 실행하고, 실패하면 statusLine 캐시로 돌아갑니다. 비공개 API라 중단될 수 있습니다.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

        }
    }

    private func requestClaudeUsageMode(_ requestedMode: ClaudeUsageMode) {
        guard requestedMode == .oauth else {
            guard requestedMode != preferences.claudeUsageMode else { return }
            selectedClaudeUsageMode = requestedMode
            oauthFeedback = nil
            preferences.claudeUsageMode = requestedMode
            return
        }
        guard !isAuthorizingClaudeOAuth else { return }

        selectedClaudeUsageMode = .oauth
        isAuthorizingClaudeOAuth = true
        oauthFeedback = nil

        Task { @MainActor in
            let result = await onAuthorizeClaudeOAuth()
            switch result {
            case .available:
                preferences.claudeUsageMode = .oauth
                oauthFeedback = .success
            case .cancelled:
                selectedClaudeUsageMode = preferences.claudeUsageMode
                oauthFeedback = .cancelled
            default:
                selectedClaudeUsageMode = preferences.claudeUsageMode
                oauthFeedback = .failure(result.userFacingMessage)
            }
            isAuthorizingClaudeOAuth = false
        }
    }
}

private enum OAuthFeedback {
    case success
    case cancelled
    case failure(String)

    var message: String {
        switch self {
        case .success:
            String(localized: "Claude OAuth 인증을 확인했습니다.")
        case .cancelled:
            String(localized: "OAuth 모드 선택을 취소했습니다.")
        case .failure(let message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .success:
            "checkmark.circle.fill"
        case .cancelled:
            "minus.circle"
        case .failure:
            "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success:
            .green
        case .cancelled:
            .secondary
        case .failure:
            .red
        }
    }
}

private extension ClaudeOAuthUserInitiatedAccessResult {
    var userFacingMessage: String {
        switch self {
        case .available:
            String(localized: "Claude OAuth 인증을 확인했습니다.")
        case .notFound:
            String(localized: "Claude OAuth 인증 정보를 파일 또는 Keychain에서 찾지 못했습니다.")
        case .denied:
            String(localized: "Claude Code Keychain 접근이 거부되었습니다.")
        case .cancelled:
            String(localized: "OAuth 모드 선택을 취소했습니다.")
        case .invalidCredentials:
            String(localized: "Claude OAuth 인증 정보를 확인할 수 없습니다.")
        case .expired:
            String(localized: "Claude OAuth 인증 정보가 만료되었습니다.")
        case .unavailable:
            String(localized: "Claude OAuth 인증 정보를 사용할 수 없습니다.")
        }
    }
}
