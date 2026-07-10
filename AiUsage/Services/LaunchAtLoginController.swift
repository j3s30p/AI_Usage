import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    enum State: Equatable, Sendable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    private(set) var state: State
    private(set) var isEnabled: Bool
    private(set) var isWorking = false
    private(set) var message: String?

    @ObservationIgnored private let service: any LaunchAtLoginServicing

    init(
        service: any LaunchAtLoginServicing = SMAppServiceLaunchAtLoginService()
    ) {
        self.service = service
        let initialState = service.state
        state = initialState
        isEnabled = Self.representsEnabledSelection(initialState)
        message = Self.statusMessage(for: initialState)
    }

    func refresh() {
        apply(service.state)
    }

    func setEnabled(_ shouldEnable: Bool) async {
        guard !isWorking else { return }

        let currentState = service.state
        apply(currentState)

        if shouldEnable {
            guard currentState != .enabled else { return }
            guard currentState != .requiresApproval else { return }
            guard currentState != .unavailable else { return }
        } else {
            guard currentState != .disabled else { return }
            guard currentState != .unavailable else { return }
        }

        isWorking = true
        isEnabled = shouldEnable
        message = nil
        defer { isWorking = false }

        do {
            if shouldEnable {
                try await service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            // SMAppService can report already-registered or not-registered errors
            // during races. The refreshed system status below remains authoritative.
        }

        apply(service.state)

        if shouldEnable, state == .requiresApproval {
            return
        }
        guard isEnabled != shouldEnable else { return }

        message = shouldEnable
            ? "로그인 시 실행을 켜지 못했습니다. 잠시 후 다시 시도해 주세요."
            : "로그인 시 실행을 끄지 못했습니다. 잠시 후 다시 시도해 주세요."
    }

    func openSystemSettingsLoginItems() {
        guard state == .requiresApproval else { return }
        service.openSystemSettingsLoginItems()
    }

    private func apply(_ newState: State) {
        state = newState
        isEnabled = Self.representsEnabledSelection(newState)
        message = Self.statusMessage(for: newState)
    }

    private static func representsEnabledSelection(_ state: State) -> Bool {
        state == .enabled || state == .requiresApproval
    }

    private static func statusMessage(for state: State) -> String? {
        switch state {
        case .disabled, .enabled:
            nil
        case .requiresApproval:
            "시스템 설정의 로그인 항목에서 AiUsage를 허용해 주세요."
        case .unavailable:
            "로그인 시 실행 상태를 확인할 수 없습니다."
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    var state: LaunchAtLoginController.State { get }

    func register() async throws
    func unregister() async throws
    func openSystemSettingsLoginItems()
}

@MainActor
final class SMAppServiceLaunchAtLoginService: LaunchAtLoginServicing {
    private let appService: SMAppService

    init(appService: SMAppService = .mainApp) {
        self.appService = appService
    }

    var state: LaunchAtLoginController.State {
        switch appService.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func register() async throws {
        try appService.register()
    }

    func unregister() async throws {
        try await appService.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
