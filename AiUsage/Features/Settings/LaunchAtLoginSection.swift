import SwiftUI

struct LaunchAtLoginSection: View {
    var body: some View {
        Section("일반") {
            Toggle(
                "로그인 시 AiUsage 자동 실행",
                isOn: .constant(false)
            )
            .disabled(true)

            Label(
                "Developer ID 서명 전 프리뷰에서는 잠시 사용할 수 없습니다.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
