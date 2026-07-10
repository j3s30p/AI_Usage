import SwiftUI

struct LaunchAtLoginSection: View {
    @Bindable var controller: LaunchAtLoginController

    var body: some View {
        Section("일반") {
            Toggle(
                "로그인 시 AiUsage 자동 실행",
                isOn: Binding(
                    get: { controller.isEnabled },
                    set: { shouldEnable in
                        Task {
                            await controller.setEnabled(shouldEnable)
                        }
                    }
                )
            )
            .disabled(
                controller.isWorking || controller.state == .unavailable
            )
            .accessibilityHint(
                "Mac에 로그인할 때 AiUsage를 자동으로 실행합니다."
            )

            if controller.isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("로그인 시 실행 설정 중…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let message = controller.message {
                Label(message, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.state == .requiresApproval {
                Button("시스템 설정 열기", systemImage: "gear") {
                    controller.openSystemSettingsLoginItems()
                }
                .accessibilityHint(
                    "로그인 항목에서 AiUsage 실행을 허용할 수 있습니다."
                )
            }
        }
        .onAppear {
            controller.refresh()
        }
    }

    private var statusSymbol: String {
        controller.state == .unavailable
            ? "xmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var statusStyle: Color {
        controller.state == .unavailable ? .red : .orange
    }
}
