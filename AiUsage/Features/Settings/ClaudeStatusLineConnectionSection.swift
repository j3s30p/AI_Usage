import SwiftUI

struct ClaudeStatusLineConnectionSection: View {
    @Bindable var model: ClaudeStatusLineSettingsModel

    @State private var showsConnectConfirmation = false
    @State private var showsDisconnectConfirmation = false

    var body: some View {
        Section("Claude statusLine 연결") {
            LabeledContent("상태") {
                Label(statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusStyle)
            }

            Text(statusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            actionControls

            if let message = model.message {
                Label(message, systemImage: messageSymbol)
                    .font(.caption)
                    .foregroundStyle(messageStyle)
                    .accessibilityLabel("Claude statusLine 연결 결과: \(message)")
            }
        }
        .task {
            await model.refresh()
        }
        .alert(
            connectConfirmationTitle,
            isPresented: $showsConnectConfirmation
        ) {
            Button("취소", role: .cancel) {}
            Button("연결 허용") {
                Task { await model.connect() }
            }
        } message: {
            Text(connectConfirmationMessage)
        }
        .alert(
            "Claude statusLine 연결을 해제할까요?",
            isPresented: $showsDisconnectConfirmation
        ) {
            Button("취소", role: .cancel) {}
            Button("연결 해제", role: .destructive) {
                Task { await model.disconnect() }
            }
        } message: {
            Text(
                "AiUsage가 추가한 연결만 제거합니다. 연결 전에 사용하던 statusLine이 있으면 원래 설정으로 복원합니다."
            )
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        if model.isWorking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Claude 연결 설정 중…")
            }
            .accessibilityElement(children: .combine)
        } else {
            switch model.state?.configuration {
            case .managedConnected:
                Button("연결 해제…", role: .destructive) {
                    showsDisconnectConfirmation = true
                }

            case .managedUpdateAvailable:
                Button("도우미 업데이트…") {
                    showsConnectConfirmation = true
                }

            case .legacyDirectAiUsageConnected:
                Button("앱에서 관리하도록 전환…") {
                    showsConnectConfirmation = true
                }

            case .foreignStatusLineMergeAvailable:
                Button("기존 표시 유지하고 연결…") {
                    showsConnectConfirmation = true
                }

            case .repairRequired:
                Button("연결 복구…") {
                    showsConnectConfirmation = true
                }

            case .blocked:
                Button("상태 다시 확인") {
                    Task { await model.refresh() }
                }

            case .disconnected:
                Button("Claude statusLine 연결…") {
                    showsConnectConfirmation = true
                }

            case nil:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("연결 상태 확인 중…")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var statusText: String {
        guard let state = model.state else { return "확인 중" }
        switch state.configuration {
        case .disconnected:
            return "연결되지 않음"
        case .foreignStatusLineMergeAvailable:
            return "기존 statusLine 감지"
        case .legacyDirectAiUsageConnected:
            return statusTextForConnectedCache(
                state.cache,
                legacy: true
            )
        case .managedConnected:
            return statusTextForConnectedCache(state.cache, legacy: false)
        case .managedUpdateAvailable:
            return "연결됨 · 업데이트 가능"
        case .repairRequired:
            return "연결 복구 필요"
        case .blocked:
            return "자동 연결 불가"
        }
    }

    private func statusTextForConnectedCache(
        _ cache: ClaudeStatusLineConnectionState.Cache,
        legacy: Bool
    ) -> String {
        switch cache {
        case .notReceived, .waiting:
            return legacy
                ? "연결됨 · 기존 방식 · Claude 응답 대기"
                : "설정 연결됨 · Claude 응답 대기"
        case .received:
            return legacy ? "연결됨 · 기존 방식" : "연결됨 · 사용량 수신됨"
        case .unsupported:
            return "연결됨 · 구독 한도 없음"
        }
    }

    private var statusDescription: String {
        guard let state = model.state else {
            return "Claude 설정을 읽기만 하며 자동으로 변경하지 않습니다."
        }
        switch state.configuration {
        case .disconnected:
            return "버튼을 누르고 동의하면 필요한 설정과 도우미를 앱이 자동으로 구성합니다."
        case .foreignStatusLineMergeAvailable:
            return "기존 statusLine 표시는 그대로 유지하면서 AiUsage 사용량 수집을 함께 연결할 수 있습니다."
        case .legacyDirectAiUsageConnected:
            return "현재 연결도 동작합니다. 앱 관리 방식으로 전환하면 설정에서 안전하게 복구하거나 해제할 수 있습니다."
        case .managedConnected:
            return "연결 설정은 완료됐습니다. Claude Code의 다음 응답부터 최신 사용량이 전달됩니다."
        case .managedUpdateAvailable:
            return "현재 연결은 계속 동작합니다. 사용자 동의 후 앱에 포함된 최신 도우미로 안전하게 업데이트할 수 있습니다."
        case .repairRequired:
            return "AiUsage가 관리하는 연결 파일 일부가 없거나 변경됐습니다. 사용자 동의 후 앱 파일만 복구합니다."
        case .blocked(let reason):
            return blockedDescription(reason)
        }
    }

    private func blockedDescription(
        _ reason: ClaudeStatusLineConnectionBlockReason
    ) -> String {
        switch reason {
        case .invalidSettings:
            return "Claude 설정이 올바른 JSON이 아니어서 아무 파일도 변경하지 않았습니다."
        case .unsupportedStatusLine:
            return "현재 statusLine 형식을 안전하게 보존할 수 없어 아무 파일도 변경하지 않았습니다."
        case .unreadableSettings:
            return "Claude 설정을 안전하게 읽을 수 없어 아무 파일도 변경하지 않았습니다."
        case .unsafeTarget:
            return "연결 경로의 소유권이나 파일 형식을 안전하게 확인할 수 없어 변경을 중단했습니다."
        }
    }

    private var statusSymbol: String {
        switch model.state?.configuration {
        case .managedConnected, .legacyDirectAiUsageConnected:
            "checkmark.circle.fill"
        case .managedUpdateAvailable:
            "arrow.down.circle.fill"
        case .repairRequired, .foreignStatusLineMergeAvailable:
            "exclamationmark.circle"
        case .blocked:
            "xmark.octagon.fill"
        case .disconnected:
            "circle.dashed"
        case nil:
            "clock"
        }
    }

    private var statusStyle: Color {
        switch model.state?.configuration {
        case .managedConnected, .legacyDirectAiUsageConnected:
            .green
        case .managedUpdateAvailable, .repairRequired,
             .foreignStatusLineMergeAvailable:
            .orange
        case .blocked:
            .red
        case .disconnected, nil:
            .secondary
        }
    }

    private var connectConfirmationTitle: String {
        switch model.state?.configuration {
        case .managedUpdateAvailable:
            "Claude statusLine 도우미를 업데이트할까요?"
        case .foreignStatusLineMergeAvailable:
            "기존 statusLine을 유지하고 연결할까요?"
        case .legacyDirectAiUsageConnected:
            "AiUsage가 연결을 관리하도록 전환할까요?"
        case .repairRequired:
            "Claude statusLine 연결을 복구할까요?"
        default:
            "Claude statusLine을 연결할까요?"
        }
    }

    private var connectConfirmationMessage: String {
        switch model.state?.configuration {
        case .managedUpdateAvailable:
            "기존 Claude 설정과 복원 정보는 그대로 유지하고, AiUsage가 설치한 도우미만 최신 버전으로 교체합니다."
        case .foreignStatusLineMergeAvailable:
            "기존 statusLine 표시를 유지하면서 AiUsage를 함께 연결합니다. 원래 설정은 백업되고 연결 해제 시 복원됩니다."
        case .legacyDirectAiUsageConnected:
            "현재 연결을 전용 관리 방식으로 옮깁니다. 변경 전 설정은 백업되며 사용량 캐시 형식은 바뀌지 않습니다."
        case .repairRequired:
            "AiUsage가 만든 연결과 도우미만 다시 구성합니다. 다른 Claude 설정은 변경하지 않습니다."
        default:
            "Claude 설정에 AiUsage 연결을 추가하고 전용 도우미를 설치합니다. 다른 설정은 유지되며 앱에서 언제든 해제할 수 있습니다."
        }
    }

    private var messageSymbol: String {
        model.messageKind == .success
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var messageStyle: Color {
        model.messageKind == .success ? .green : .orange
    }
}
