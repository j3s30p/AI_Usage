import XCTest
@testable import AiUsage

@MainActor
final class ClaudeStatusLineSettingsModelTests: XCTestCase {
    func testRefreshPublishesInspectedState() async {
        let inspectedState = makeState(
            configuration: .foreignStatusLineMergeAvailable,
            cache: .received
        )
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: inspectedState
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        await model.refresh()

        XCTAssertEqual(model.state, inspectedState)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.message)
        XCTAssertNil(model.messageKind)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.inspect, 1)
        XCTAssertEqual(calls.connect, 0)
        XCTAssertEqual(calls.disconnect, 0)
    }

    func testConnectPublishesSuccessStateAndMessageKind() async {
        let connectedState = makeState(
            configuration: .managedConnected,
            cache: .waiting
        )
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: makeState(configuration: .disconnected),
            connectResult: connectedState
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let connected = await model.connect()

        XCTAssertTrue(connected)
        XCTAssertEqual(model.state, connectedState)
        XCTAssertEqual(model.message, "Claude statusLine 연결을 완료했습니다.")
        XCTAssertEqual(model.messageKind, .success)
        XCTAssertFalse(model.isWorking)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.connect, 1)
        XCTAssertEqual(calls.inspect, 0)
    }

    func testConnectFromUpdateAvailablePublishesUpdateMessage() async {
        let updateState = makeState(configuration: .managedUpdateAvailable)
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: updateState,
            connectResult: makeState(configuration: .managedConnected)
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)
        await model.refresh()

        let connected = await model.connect()

        XCTAssertTrue(connected)
        XCTAssertEqual(model.state?.configuration, .managedConnected)
        XCTAssertEqual(
            model.message,
            "Claude statusLine 도우미를 업데이트했습니다."
        )
        XCTAssertEqual(model.messageKind, .success)
    }

    func testDisconnectPublishesSuccessStateAndMessageKind() async {
        let disconnectedState = makeState(configuration: .disconnected)
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: makeState(configuration: .managedConnected),
            disconnectResult: disconnectedState
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let disconnected = await model.disconnect()

        XCTAssertTrue(disconnected)
        XCTAssertEqual(model.state, disconnectedState)
        XCTAssertEqual(
            model.message,
            "AiUsage 연결을 해제하고 기존 statusLine을 복원했습니다."
        )
        XCTAssertEqual(model.messageKind, .success)
        XCTAssertFalse(model.isWorking)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.disconnect, 1)
        XCTAssertEqual(calls.inspect, 0)
    }

    func testRefreshClearsFeedbackFromAnEarlierMutation() async {
        let refreshedState = makeState(configuration: .repairRequired)
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: refreshedState,
            connectResult: makeState(configuration: .managedConnected)
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let connected = await model.connect()
        XCTAssertTrue(connected)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.messageKind, .success)

        await model.refresh()

        XCTAssertEqual(model.state, refreshedState)
        XCTAssertNil(model.message)
        XCTAssertNil(model.messageKind)
    }

    func testConnectFailureRefreshesStateWithoutExposingSensitiveError() async {
        let refreshedState = makeState(configuration: .repairRequired)
        let secret = "sensitive path and command must stay private"
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: refreshedState,
            connectFailure: .sensitive(secret)
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let connected = await model.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(model.state, refreshedState)
        XCTAssertEqual(
            model.message,
            "Claude statusLine 연결을 완료하지 못했습니다."
        )
        XCTAssertEqual(model.messageKind, .error)
        XCTAssertFalse(model.message?.contains(secret) == true)
        XCTAssertFalse(model.isWorking)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.connect, 1)
        XCTAssertEqual(calls.inspect, 1)
    }

    func testDisconnectFailureRefreshesStateWithoutExposingSensitiveError() async {
        let refreshedState = makeState(configuration: .managedConnected)
        let secret = "private settings contents"
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: refreshedState,
            disconnectFailure: .sensitive(secret)
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let disconnected = await model.disconnect()

        XCTAssertFalse(disconnected)
        XCTAssertEqual(model.state, refreshedState)
        XCTAssertEqual(
            model.message,
            "Claude statusLine 연결을 안전하게 해제하지 못했습니다."
        )
        XCTAssertEqual(model.messageKind, .error)
        XCTAssertFalse(model.message?.contains(secret) == true)
        XCTAssertFalse(model.isWorking)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.disconnect, 1)
        XCTAssertEqual(calls.inspect, 1)
    }

    func testKnownConnectionErrorUsesOnlySanitizedLocalizedMessage() async {
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: makeState(
                configuration: .blocked(.unsafeTarget)
            ),
            connectFailure: .connection(.unsafeTarget)
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let connected = await model.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(
            model.message,
            ClaudeStatusLineConnectionError.unsafeTarget.localizedDescription
        )
        XCTAssertEqual(model.messageKind, .error)
    }

    func testMutatingOperationBlocksRefreshConnectAndDisconnectDuplicates() async {
        let gate = StatusLineSettingsAsyncGate()
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: makeState(configuration: .disconnected),
            connectResult: makeState(configuration: .managedConnected),
            connectGate: gate
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let firstConnect = Task { @MainActor in
            await model.connect()
        }
        let didStart = await waitUntil {
            await manager.callCounts().connect == 1
        }
        XCTAssertTrue(didStart)
        XCTAssertTrue(model.isWorking)

        await model.refresh()
        let duplicateConnect = await model.connect()
        let duplicateDisconnect = await model.disconnect()

        XCTAssertFalse(duplicateConnect)
        XCTAssertFalse(duplicateDisconnect)
        let callsWhileBlocked = await manager.callCounts()
        XCTAssertEqual(callsWhileBlocked.inspect, 0)
        XCTAssertEqual(callsWhileBlocked.connect, 1)
        XCTAssertEqual(callsWhileBlocked.disconnect, 0)

        await gate.open()
        let firstConnectResult = await firstConnect.value
        XCTAssertTrue(firstConnectResult)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.state?.configuration, .managedConnected)
    }

    func testConcurrentRefreshesInspectOnlyOnce() async {
        let gate = StatusLineSettingsAsyncGate()
        let inspectedState = makeState(configuration: .disconnected)
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: inspectedState,
            inspectGate: gate
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let firstRefresh = Task { @MainActor in
            await model.refresh()
        }
        let didStart = await waitUntil {
            await manager.callCounts().inspect == 1
        }
        XCTAssertTrue(didStart)

        await model.refresh()
        let callsWhileRefreshing = await manager.callCounts()
        XCTAssertEqual(callsWhileRefreshing.inspect, 1)

        await gate.open()
        await firstRefresh.value
        XCTAssertEqual(model.state, inspectedState)
    }

    func testMutationDiscardsLateRefreshResult() async {
        let gate = StatusLineSettingsAsyncGate()
        let staleState = makeState(configuration: .disconnected)
        let connectedState = makeState(
            configuration: .managedConnected,
            cache: .received
        )
        let manager = FakeClaudeStatusLineConnectionManager(
            inspectResult: staleState,
            connectResult: connectedState,
            inspectGate: gate
        )
        let model = ClaudeStatusLineSettingsModel(manager: manager)

        let refresh = Task { @MainActor in
            await model.refresh()
        }
        let didStart = await waitUntil {
            await manager.callCounts().inspect == 1
        }
        XCTAssertTrue(didStart)

        let connected = await model.connect()
        XCTAssertTrue(connected)
        XCTAssertEqual(model.state, connectedState)
        XCTAssertEqual(model.messageKind, .success)

        await gate.open()
        await refresh.value

        XCTAssertEqual(model.state, connectedState)
        XCTAssertEqual(model.messageKind, .success)
        let calls = await manager.callCounts()
        XCTAssertEqual(calls.inspect, 1)
        XCTAssertEqual(calls.connect, 1)
    }

    private func makeState(
        configuration: ClaudeStatusLineConnectionState.Configuration,
        cache: ClaudeStatusLineConnectionState.Cache = .notReceived
    ) -> ClaudeStatusLineConnectionState {
        ClaudeStatusLineConnectionState(
            configuration: configuration,
            cache: cache
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor FakeClaudeStatusLineConnectionManager:
    ClaudeStatusLineConnectionManaging
{
    enum Failure: Sendable {
        case sensitive(String)
        case connection(ClaudeStatusLineConnectionError)
        case cancelled
    }

    struct CallCounts: Sendable {
        let inspect: Int
        let connect: Int
        let disconnect: Int
    }

    private let inspectResult: ClaudeStatusLineConnectionState
    private let connectResult: ClaudeStatusLineConnectionState
    private let disconnectResult: ClaudeStatusLineConnectionState
    private let connectFailure: Failure?
    private let disconnectFailure: Failure?
    private let inspectGate: StatusLineSettingsAsyncGate?
    private let connectGate: StatusLineSettingsAsyncGate?
    private let disconnectGate: StatusLineSettingsAsyncGate?
    private var inspectCallCount = 0
    private var connectCallCount = 0
    private var disconnectCallCount = 0

    init(
        inspectResult: ClaudeStatusLineConnectionState,
        connectResult: ClaudeStatusLineConnectionState? = nil,
        disconnectResult: ClaudeStatusLineConnectionState? = nil,
        connectFailure: Failure? = nil,
        disconnectFailure: Failure? = nil,
        inspectGate: StatusLineSettingsAsyncGate? = nil,
        connectGate: StatusLineSettingsAsyncGate? = nil,
        disconnectGate: StatusLineSettingsAsyncGate? = nil
    ) {
        self.inspectResult = inspectResult
        self.connectResult = connectResult ?? inspectResult
        self.disconnectResult = disconnectResult ?? inspectResult
        self.connectFailure = connectFailure
        self.disconnectFailure = disconnectFailure
        self.inspectGate = inspectGate
        self.connectGate = connectGate
        self.disconnectGate = disconnectGate
    }

    func inspect() async -> ClaudeStatusLineConnectionState {
        inspectCallCount += 1
        let result = inspectResult
        if let inspectGate {
            await inspectGate.wait()
        }
        return result
    }

    func connect() async throws -> ClaudeStatusLineConnectionState {
        connectCallCount += 1
        if let connectGate {
            await connectGate.wait()
        }
        try throwIfNeeded(connectFailure)
        return connectResult
    }

    func disconnect() async throws -> ClaudeStatusLineConnectionState {
        disconnectCallCount += 1
        if let disconnectGate {
            await disconnectGate.wait()
        }
        try throwIfNeeded(disconnectFailure)
        return disconnectResult
    }

    func callCounts() -> CallCounts {
        CallCounts(
            inspect: inspectCallCount,
            connect: connectCallCount,
            disconnect: disconnectCallCount
        )
    }

    private func throwIfNeeded(_ failure: Failure?) throws {
        switch failure {
        case .sensitive(let detail):
            throw SensitiveStatusLineSettingsError(detail: detail)
        case .connection(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        case nil:
            return
        }
    }
}

private actor StatusLineSettingsAsyncGate {
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

private struct SensitiveStatusLineSettingsError: LocalizedError, Sendable {
    let detail: String

    var errorDescription: String? { detail }
}
