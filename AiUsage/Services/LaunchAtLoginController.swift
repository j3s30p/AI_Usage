import Foundation
import Observation
import OSLog
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    enum ServiceOperation: String, Equatable, Sendable {
        case register
        case unregister
    }

    struct ServiceErrorMetadata: Equatable, Sendable {
        let operation: ServiceOperation
        let domain: String
        let code: Int
    }

    typealias ServiceErrorLogger = @MainActor (ServiceErrorMetadata) -> Void

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
    @ObservationIgnored private let serviceErrorLogger: ServiceErrorLogger

    init(
        service: any LaunchAtLoginServicing = SMAppServiceLaunchAtLoginService(),
        serviceErrorLogger: @escaping ServiceErrorLogger = { metadata in
            Logger.launchAtLogin.error(
                "SMAppService \(metadata.operation.rawValue, privacy: .public) returned error; domain=\(metadata.domain, privacy: .public) code=\(metadata.code, privacy: .public)"
            )
        }
    ) {
        self.service = service
        self.serviceErrorLogger = serviceErrorLogger
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
        } else {
            guard currentState != .disabled else { return }
            guard currentState != .unavailable else { return }
        }

        isWorking = true
        isEnabled = shouldEnable
        message = nil
        defer { isWorking = false }

        var operationError: (any Error)?
        do {
            if shouldEnable {
                try await service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            operationError = error
            // SMAppService can report already-registered or not-registered errors
            // during races. The refreshed system status below remains authoritative.
        }

        apply(service.state)

        if shouldEnable, state == .requiresApproval {
            return
        }
        guard isEnabled != shouldEnable else { return }

        if let operationError {
            logServiceError(
                operationError,
                operation: shouldEnable ? .register : .unregister
            )
        }

        message = shouldEnable
            ? String(localized: "로그인 시 실행을 켜지 못했습니다. 잠시 후 다시 시도해 주세요.")
            : String(localized: "로그인 시 실행을 끄지 못했습니다. 잠시 후 다시 시도해 주세요.")
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

    private func logServiceError(
        _ error: any Error,
        operation: ServiceOperation
    ) {
        let nsError = error as NSError
        serviceErrorLogger(
            ServiceErrorMetadata(
                operation: operation,
                domain: nsError.domain,
                code: nsError.code
            )
        )
    }

    private static func representsEnabledSelection(_ state: State) -> Bool {
        state == .enabled || state == .requiresApproval
    }

    private static func statusMessage(for state: State) -> String? {
        switch state {
        case .disabled, .enabled:
            nil
        case .requiresApproval:
            String(localized: "시스템 설정의 로그인 항목에서 AiUsage를 허용해 주세요.")
        case .unavailable:
            String(localized: "로그인 시 실행 상태를 확인할 수 없습니다. 토글을 켜 다시 등록해 주세요.")
        }
    }
}

private extension Logger {
    static let launchAtLogin = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.j3s30p.AiUsage",
        category: "LaunchAtLogin"
    )
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
