import Observation

@MainActor
@Observable
final class ClaudeStatusLineSettingsModel {
    enum MessageKind: Equatable {
        case success
        case error
    }

    private(set) var state: ClaudeStatusLineConnectionState?
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var messageKind: MessageKind?

    @ObservationIgnored
    private let manager: any ClaudeStatusLineConnectionManaging
    @ObservationIgnored
    private var isRefreshing = false
    @ObservationIgnored
    private var operationGeneration = 0

    init(
        manager: any ClaudeStatusLineConnectionManaging =
            ClaudeStatusLineConnectionManager()
    ) {
        self.manager = manager
    }

    func refresh() async {
        guard !isWorking, !isRefreshing else { return }
        isRefreshing = true
        let generation = operationGeneration
        let refreshedState = await manager.inspect()
        isRefreshing = false

        guard !isWorking, generation == operationGeneration else { return }
        state = refreshedState
        message = nil
        messageKind = nil
    }

    @discardableResult
    func connect() async -> Bool {
        guard !isWorking else { return false }
        let isUpdating = state?.configuration == .managedUpdateAvailable
        isWorking = true
        operationGeneration += 1
        message = nil
        messageKind = nil
        defer { isWorking = false }

        do {
            state = try await manager.connect()
            message = isUpdating
                ? String(localized: "Claude statusLine 도우미를 업데이트했습니다.")
                : String(localized: "Claude statusLine 연결을 완료했습니다.")
            messageKind = .success
            return true
        } catch is CancellationError {
            return false
        } catch let error as ClaudeStatusLineConnectionError {
            message = error.localizedDescription
            messageKind = .error
        } catch {
            message = String(localized: "Claude statusLine 연결을 완료하지 못했습니다.")
            messageKind = .error
        }
        state = await manager.inspect()
        return false
    }

    @discardableResult
    func disconnect() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        operationGeneration += 1
        message = nil
        messageKind = nil
        defer { isWorking = false }

        do {
            state = try await manager.disconnect()
            message = String(localized: "AiUsage 연결을 해제하고 기존 statusLine을 복원했습니다.")
            messageKind = .success
            return true
        } catch is CancellationError {
            return false
        } catch let error as ClaudeStatusLineConnectionError {
            message = error.localizedDescription
            messageKind = .error
        } catch {
            message = String(localized: "Claude statusLine 연결을 안전하게 해제하지 못했습니다.")
            messageKind = .error
        }
        state = await manager.inspect()
        return false
    }
}
