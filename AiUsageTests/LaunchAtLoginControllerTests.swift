import XCTest
@testable import AiUsage

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testInitialStateComesFromService() {
        let enabled = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(state: .enabled)
        )
        let requiresApproval = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(state: .requiresApproval)
        )
        let unavailable = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(state: .unavailable)
        )

        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertNil(enabled.message)

        XCTAssertEqual(requiresApproval.state, .requiresApproval)
        XCTAssertTrue(requiresApproval.isEnabled)
        XCTAssertEqual(
            requiresApproval.message,
            "시스템 설정의 로그인 항목에서 AiUsage를 허용해 주세요."
        )

        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertEqual(
            unavailable.message,
            "로그인 시 실행 상태를 확인할 수 없습니다."
        )
    }

    func testEnableRegistersAndRefreshesFromService() async {
        let service = FakeLaunchAtLoginService(state: .disabled)
        service.stateAfterRegister = .enabled
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.message)
    }

    func testDisableUnregistersAndRefreshesFromService() async {
        let service = FakeLaunchAtLoginService(state: .enabled)
        service.stateAfterUnregister = .disabled
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.message)
    }

    func testDisablePendingApprovalUnregistersTheLoginItem() async {
        let service = FakeLaunchAtLoginService(state: .requiresApproval)
        service.stateAfterUnregister = .disabled
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.message)
    }

    func testRegistrationCanRequireApprovalAndOpenSystemSettings() async {
        let service = FakeLaunchAtLoginService(state: .disabled)
        service.stateAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(
            controller.message,
            "시스템 설정의 로그인 항목에서 AiUsage를 허용해 주세요."
        )

        controller.openSystemSettingsLoginItems()
        XCTAssertEqual(service.openSettingsCallCount, 1)
    }

    func testOpenSystemSettingsIsIgnoredUnlessApprovalIsRequired() {
        let service = FakeLaunchAtLoginService(state: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.openSystemSettingsLoginItems()

        XCTAssertEqual(service.openSettingsCallCount, 0)
    }

    func testRegisterFailureRollsBackToggleAndSanitizesMessage() async {
        let service = FakeLaunchAtLoginService(state: .disabled)
        service.registerError = SensitiveTestError("secret register detail")
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(
            controller.message,
            "로그인 시 실행을 켜지 못했습니다. 잠시 후 다시 시도해 주세요."
        )
        XCTAssertFalse(controller.message?.contains("secret register detail") == true)
    }

    func testUnregisterFailureRollsBackToggleAndSanitizesMessage() async {
        let service = FakeLaunchAtLoginService(state: .enabled)
        service.unregisterError = SensitiveTestError("secret unregister detail")
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(
            controller.message,
            "로그인 시 실행을 끄지 못했습니다. 잠시 후 다시 시도해 주세요."
        )
        XCTAssertFalse(controller.message?.contains("secret unregister detail") == true)
    }

    func testAlreadyEnabledAndAlreadyDisabledActionsAreIdempotent() async {
        let enabledService = FakeLaunchAtLoginService(state: .enabled)
        let enabledController = LaunchAtLoginController(service: enabledService)
        let disabledService = FakeLaunchAtLoginService(state: .disabled)
        let disabledController = LaunchAtLoginController(service: disabledService)

        await enabledController.setEnabled(true)
        await disabledController.setEnabled(false)

        XCTAssertEqual(enabledService.registerCallCount, 0)
        XCTAssertEqual(disabledService.unregisterCallCount, 0)
        XCTAssertTrue(enabledController.isEnabled)
        XCTAssertFalse(disabledController.isEnabled)
    }

    func testRaceErrorsAreTreatedAsSuccessWhenSystemStateMatchesRequest() async {
        let registerService = FakeLaunchAtLoginService(state: .disabled)
        registerService.stateBeforeRegisterError = .enabled
        registerService.registerError = SensitiveTestError("already registered")
        let registerController = LaunchAtLoginController(service: registerService)

        let unregisterService = FakeLaunchAtLoginService(state: .enabled)
        unregisterService.stateBeforeUnregisterError = .disabled
        unregisterService.unregisterError = SensitiveTestError("not registered")
        let unregisterController = LaunchAtLoginController(service: unregisterService)

        await registerController.setEnabled(true)
        await unregisterController.setEnabled(false)

        XCTAssertEqual(registerController.state, .enabled)
        XCTAssertTrue(registerController.isEnabled)
        XCTAssertNil(registerController.message)
        XCTAssertEqual(unregisterController.state, .disabled)
        XCTAssertFalse(unregisterController.isEnabled)
        XCTAssertNil(unregisterController.message)
    }

    func testRefreshReconcilesExternalSystemSettingsChanges() {
        let service = FakeLaunchAtLoginService(state: .disabled)
        let controller = LaunchAtLoginController(service: service)

        service.state = .enabled
        controller.refresh()

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.message)

        service.state = .requiresApproval
        controller.refresh()

        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.message)
    }

    func testDuplicateActionsAreIgnoredWhileOperationIsRunning() async {
        let gate = AsyncGate()
        let service = FakeLaunchAtLoginService(state: .disabled)
        service.registerGate = gate
        service.stateAfterRegister = .enabled
        let controller = LaunchAtLoginController(service: service)

        let firstAction = Task { @MainActor in
            await controller.setEnabled(true)
        }
        let didStart = await waitUntil {
            service.registerCallCount == 1
        }
        XCTAssertTrue(didStart)
        XCTAssertTrue(controller.isWorking)
        XCTAssertTrue(controller.isEnabled)

        await controller.setEnabled(true)
        XCTAssertEqual(service.registerCallCount, 1)

        await gate.open()
        await firstAction.value

        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.state, .enabled)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginController.State
    var stateAfterRegister: LaunchAtLoginController.State?
    var stateAfterUnregister: LaunchAtLoginController.State?
    var stateBeforeRegisterError: LaunchAtLoginController.State?
    var stateBeforeUnregisterError: LaunchAtLoginController.State?
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    var registerGate: AsyncGate?
    var unregisterGate: AsyncGate?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(state: LaunchAtLoginController.State) {
        self.state = state
    }

    func register() async throws {
        registerCallCount += 1
        if let registerGate {
            await registerGate.wait()
        }
        if let stateBeforeRegisterError {
            state = stateBeforeRegisterError
        }
        if let registerError {
            throw registerError
        }
        if let stateAfterRegister {
            state = stateAfterRegister
        }
    }

    func unregister() async throws {
        unregisterCallCount += 1
        if let unregisterGate {
            await unregisterGate.wait()
        }
        if let stateBeforeUnregisterError {
            state = stateBeforeUnregisterError
        }
        if let unregisterError {
            throw unregisterError
        }
        if let stateAfterUnregister {
            state = stateAfterUnregister
        }
    }

    func openSystemSettingsLoginItems() {
        openSettingsCallCount += 1
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private struct SensitiveTestError: LocalizedError {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }

    var errorDescription: String? { detail }
}
