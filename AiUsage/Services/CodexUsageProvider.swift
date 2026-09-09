import Foundation

protocol CodexAppServerServing: AnyObject, Sendable {
    var notifications: AsyncStream<CodexAppServerNotification> { get }
    var isRunning: Bool { get }

    func initialize() async throws
    func fetchRateLimits() async throws -> CodexRateLimitsResponse
    func shutdown()
}

extension CodexAppServerClient: CodexAppServerServing {}

final actor CodexUsageProvider: UsageFetching {
    nonisolated let provider = UsageProvider.codex

    typealias ClientFactory = @Sendable () throws -> any CodexAppServerServing
    typealias LocalUpdateStreamFactory = @Sendable () -> AsyncStream<UsageSnapshot>

    private static let effectivelyFullRemainingFraction = 0.995
    private static let initialConfirmationReadCount = 2

    private struct ConnectionOperation {
        let id: UUID
        let clientID: UUID
        let task: Task<Void, any Error>
    }

    private struct ReadResult: Sendable {
        let id: UUID
        let snapshot: UsageSnapshot
    }

    private struct ReadOperation {
        let id: UUID
        let task: Task<ReadResult, any Error>
    }

    private struct Subscriber {
        let session: UInt64
        let continuation: AsyncStream<ProviderUsageResult>.Continuation
    }

    private struct SnapshotShape: Equatable {
        let hasFiveHour: Bool
        let hasWeekly: Bool
    }

    private enum WaitOutcome {
        case refresh
        case connectionClosed
        case cancelled
    }

    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var monitoring = false
        private var shutDown = false

        func beginMonitoring() -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard !shutDown else { return nil }
            generation &+= 1
            monitoring = true
            return generation
        }

        func stopMonitoring() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            monitoring = false
            return generation
        }

        func shutdown() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            monitoring = false
            shutDown = true
            return generation
        }

        func isActive(_ session: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !shutDown && monitoring && generation == session
        }

        func isCurrentStop(_ generation: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !shutDown && !monitoring && self.generation == generation
        }

        var isShutdown: Bool {
            lock.lock()
            defer { lock.unlock() }
            return shutDown
        }
    }

    private static let defaultReconnectBackoff: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(30),
    ]

    private let clientFactory: ClientFactory
    private let localUpdates: LocalUpdateStreamFactory
    private let reconnectBackoff: [Duration]
    private let lifecycle = Lifecycle()

    private var client: (id: UUID, value: any CodexAppServerServing)?
    private var initializedClientID: UUID?
    private var connectionOperation: ConnectionOperation?
    private var readOperation: ReadOperation?
    private var notificationTask: Task<Void, Never>?
    private var notificationCoalesceTask: Task<Void, Never>?
    private var localUpdateTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var monitorSleep: (id: UUID, task: Task<Void, any Error>)?
    private var activeSession: UInt64?
    private var subscribers: [UUID: Subscriber] = [:]
    private var lastPublishedReadID: UUID?
    private var outageFailureEmitted = false
    private var pendingImmediateRefresh = false
    private var pendingConnectionClosed = false
    private var latestPublishedSnapshotFetchedAt: Date?
    private var latestPublishedSnapshotShape: SnapshotShape?

    init(
        executableURL: URL? = nil,
        arguments: [String]? = nil,
        requestTimeout: TimeInterval = 8,
        reconnectBackoff: [Duration] = CodexUsageProvider.defaultReconnectBackoff,
        localUpdates: @escaping LocalUpdateStreamFactory = {
            CodexUsageProvider.makeDefaultLocalUpdates()
        }
    ) {
        clientFactory = {
            guard let url = executableURL ?? ExecutableLocator.locate("codex") else {
                throw UsageServiceError.executableNotFound("Codex")
            }
            return try CodexAppServerClient(
                executableURL: url,
                arguments: arguments,
                requestTimeout: requestTimeout
            )
        }
        self.reconnectBackoff = reconnectBackoff.isEmpty
            ? Self.defaultReconnectBackoff
            : reconnectBackoff
        self.localUpdates = localUpdates
    }

    init(
        clientFactory: @escaping ClientFactory,
        reconnectBackoff: [Duration] = CodexUsageProvider.defaultReconnectBackoff,
        localUpdates: @escaping LocalUpdateStreamFactory = {
            CodexUsageProvider.emptyLocalUpdates()
        }
    ) {
        self.clientFactory = clientFactory
        self.reconnectBackoff = reconnectBackoff.isEmpty
            ? Self.defaultReconnectBackoff
            : reconnectBackoff
        self.localUpdates = localUpdates
    }

    nonisolated func updates(
        refreshInterval: Duration = .seconds(180)
    ) -> AsyncStream<ProviderUsageResult> {
        guard let session = lifecycle.beginMonitoring() else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let subscriberID = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
            Task {
                await addSubscriber(
                    id: subscriberID,
                    session: session,
                    refreshInterval: refreshInterval,
                    continuation: continuation
                )
            }
        }
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard !lifecycle.isShutdown else {
            throw UsageServiceError.processClosed("Codex")
        }

        do {
            let result = try await authoritativeRead()
            if let session = activeSession, lifecycle.isActive(session) {
                publishSuccess(result)
            }
            return result.snapshot
        } catch {
            signalConnectionFailure()
            throw error
        }
    }

    nonisolated func stopMonitoring() {
        let stopGeneration = lifecycle.stopMonitoring()
        Task { [weak self] in
            await self?.stopMonitoringIsolated(generation: stopGeneration)
        }
    }

    nonisolated func shutdown() {
        _ = lifecycle.shutdown()
        Task { [weak self] in
            await self?.shutdownIsolated()
        }
    }

    deinit {
        _ = lifecycle.shutdown()
        monitorTask?.cancel()
        monitorSleep?.task.cancel()
        notificationTask?.cancel()
        notificationCoalesceTask?.cancel()
        localUpdateTask?.cancel()
        connectionOperation?.task.cancel()
        readOperation?.task.cancel()
        client?.value.shutdown()
    }

    private func addSubscriber(
        id: UUID,
        session: UInt64,
        refreshInterval: Duration,
        continuation: AsyncStream<ProviderUsageResult>.Continuation
    ) {
        guard lifecycle.isActive(session) else {
            continuation.finish()
            return
        }

        subscribers[id] = Subscriber(session: session, continuation: continuation)
        if activeSession != session {
            latestPublishedSnapshotFetchedAt = nil
            latestPublishedSnapshotShape = nil
        }
        activeSession = session
        restartMonitor(session: session, refreshInterval: refreshInterval)
        startLocalUpdateListener(session: session)
    }

    private func removeSubscriber(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil,
            subscribers.isEmpty
        else { return }

        let generation = lifecycle.stopMonitoring()
        stopMonitoringIsolated(generation: generation)
    }

    private func restartMonitor(session: UInt64, refreshInterval: Duration) {
        monitorTask?.cancel()
        monitorSleep?.task.cancel()
        notificationCoalesceTask?.cancel()
        notificationCoalesceTask = nil
        monitorSleep = nil
        pendingImmediateRefresh = false
        pendingConnectionClosed = false

        monitorTask = Task { [weak self] in
            await self?.runMonitor(session: session, refreshInterval: refreshInterval)
        }
    }

    private func startLocalUpdateListener(session: UInt64) {
        localUpdateTask?.cancel()
        let updates = localUpdates()
        localUpdateTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.handleLocalSnapshot(snapshot, session: session)
            }
        }
    }

    private func runMonitor(session: UInt64, refreshInterval: Duration) async {
        var backoffIndex = 0

        while lifecycle.isActive(session), !Task.isCancelled {
            do {
                let read = try await authoritativeRead()
                guard lifecycle.isActive(session), !Task.isCancelled else { return }
                publishSuccess(read)
                backoffIndex = 0

                switch await waitForRefresh(
                    session: session,
                    refreshInterval: refreshInterval
                ) {
                case .refresh:
                    continue
                case .connectionClosed:
                    throw UsageServiceError.processClosed("Codex")
                case .cancelled:
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard lifecycle.isActive(session), !Task.isCancelled else { return }
                publishFailureOnce(error)
                disconnectClient()

                let delay = reconnectBackoff[min(backoffIndex, reconnectBackoff.count - 1)]
                backoffIndex = min(backoffIndex + 1, reconnectBackoff.count - 1)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func waitForRefresh(
        session: UInt64,
        refreshInterval: Duration
    ) async -> WaitOutcome {
        if pendingConnectionClosed {
            pendingConnectionClosed = false
            return .connectionClosed
        }
        if pendingImmediateRefresh {
            pendingImmediateRefresh = false
            return .refresh
        }

        let sleepID = UUID()
        let task = Task { try await Task.sleep(for: refreshInterval) }
        monitorSleep = (sleepID, task)

        do {
            try await task.value
            if monitorSleep?.id == sleepID { monitorSleep = nil }
            return lifecycle.isActive(session) ? .refresh : .cancelled
        } catch {
            if monitorSleep?.id == sleepID { monitorSleep = nil }
            guard lifecycle.isActive(session), !Task.isCancelled else { return .cancelled }
            if pendingConnectionClosed {
                pendingConnectionClosed = false
                return .connectionClosed
            }
            if pendingImmediateRefresh {
                pendingImmediateRefresh = false
                return .refresh
            }
            return .cancelled
        }
    }

    private func authoritativeRead() async throws -> ReadResult {
        if let operation = readOperation {
            let result = try await operation.task.value
            return result
        }

        let connectedClient = try await ensureConnected()
        // Connection initialization is an actor reentrancy point. Another caller may have
        // installed the shared read while this caller was waiting for the same handshake.
        if let operation = readOperation {
            let result = try await operation.task.value
            return result
        }

        let operationID = UUID()
        let task = Task {
            let fetchedAt = Date()
            let response = try await connectedClient.fetchRateLimits()
            let initialSnapshot = try Self.makeSnapshot(from: response, fetchedAt: fetchedAt)
            let snapshot: UsageSnapshot
            if initialSnapshot.remainingFraction >= Self.effectivelyFullRemainingFraction {
                snapshot = try await Self.confirmInitialFullSnapshot(
                    initialSnapshot,
                    using: connectedClient
                )
            } else {
                snapshot = initialSnapshot
            }
            return ReadResult(
                id: operationID,
                snapshot: snapshot
            )
        }
        readOperation = ReadOperation(id: operationID, task: task)

        do {
            let result = try await task.value
            if readOperation?.id == operationID {
                readOperation = nil
                disconnectClient()
            }
            return result
        } catch {
            if readOperation?.id == operationID { readOperation = nil }
            throw error
        }
    }

    nonisolated private static func confirmInitialFullSnapshot(
        _ initialSnapshot: UsageSnapshot,
        using client: any CodexAppServerServing
    ) async throws -> UsageSnapshot {
        var selectedSnapshot = initialSnapshot

        for _ in 0..<initialConfirmationReadCount {
            do {
                try Task.checkCancellation()
                let fetchedAt = Date()
                let response = try await client.fetchRateLimits()
                let candidate = try makeSnapshot(from: response, fetchedAt: fetchedAt)
                guard let candidateResetAt = candidate.resetAt,
                      let selectedResetAt = selectedSnapshot.resetAt
                else { continue }
                if candidateResetAt > selectedResetAt
                    || (candidateResetAt == selectedResetAt
                        && candidate.fetchedAt > selectedSnapshot.fetchedAt)
                {
                    selectedSnapshot = candidate
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Confirmation is best-effort. The first valid snapshot remains usable.
                continue
            }
        }

        return selectedSnapshot
    }

    private func ensureConnected() async throws -> any CodexAppServerServing {
        if let connectionOperation {
            return try await finishConnection(connectionOperation)
        }

        if let client, initializedClientID == client.id, client.value.isRunning {
            return client.value
        }

        guard !lifecycle.isShutdown else {
            throw UsageServiceError.processClosed("Codex")
        }
        disconnectClient()

        let newClient = try clientFactory()
        let clientID = UUID()
        client = (clientID, newClient)
        let operationID = UUID()
        let task = Task { try await newClient.initialize() }
        connectionOperation = ConnectionOperation(
            id: operationID,
            clientID: clientID,
            task: task
        )

        return try await finishConnection(
            ConnectionOperation(id: operationID, clientID: clientID, task: task)
        )
    }

    private func finishConnection(
        _ operation: ConnectionOperation
    ) async throws -> any CodexAppServerServing {
        do {
            try await operation.task.value
            guard !lifecycle.isShutdown,
                let client,
                client.id == operation.clientID,
                client.value.isRunning
            else {
                throw UsageServiceError.processClosed("Codex")
            }

            if initializedClientID != operation.clientID {
                initializedClientID = operation.clientID
                startNotificationListener(
                    for: client.value,
                    clientID: operation.clientID
                )
            }
            if connectionOperation?.id == operation.id { connectionOperation = nil }
            return client.value
        } catch {
            if connectionOperation?.id == operation.id { connectionOperation = nil }
            if client?.id == operation.clientID { disconnectClient() }
            throw error
        }
    }

    private func startNotificationListener(
        for client: any CodexAppServerServing,
        clientID: UUID
    ) {
        notificationTask?.cancel()
        let notifications = client.notifications
        notificationTask = Task { [weak self] in
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                await self?.handle(notification, clientID: clientID)
            }
            await self?.notificationStreamEnded(clientID: clientID)
        }
    }

    private func handle(_ notification: CodexAppServerNotification, clientID: UUID) {
        guard client?.id == clientID,
            notification.method == "account/rateLimits/updated"
        else { return }

        // App-server can emit several rate-limit updates for one turn. Debounce the burst,
        // then wake the monitor for one authoritative read.
        guard notificationCoalesceTask == nil else { return }
        notificationCoalesceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushNotificationRefresh(clientID: clientID)
        }
    }

    private func flushNotificationRefresh(clientID: UUID) {
        notificationCoalesceTask = nil
        guard client?.id == clientID else { return }
        // An in-flight read already provides the authoritative state for this burst.
        guard readOperation == nil else { return }
        pendingImmediateRefresh = true
        monitorSleep?.task.cancel()
    }

    private func notificationStreamEnded(clientID: UUID) {
        guard client?.id == clientID, client?.value.isRunning == false else { return }
        pendingConnectionClosed = true
        readOperation?.task.cancel()
        monitorSleep?.task.cancel()
    }

    private func signalConnectionFailure() {
        guard activeSession != nil else {
            disconnectClient()
            return
        }
        pendingConnectionClosed = true
        monitorSleep?.task.cancel()
    }

    private func publishSuccess(_ read: ReadResult) {
        guard lastPublishedReadID != read.id else { return }
        lastPublishedReadID = read.id
        guard accepts(snapshot: read.snapshot, allowShapeChange: true) else { return }
        outageFailureEmitted = false
        let result = ProviderUsageResult.success(read.snapshot)
        recordAccepted(snapshot: read.snapshot)
        yield(result)
    }

    private func handleLocalSnapshot(_ snapshot: UsageSnapshot, session: UInt64) {
        guard lifecycle.isActive(session), activeSession == session,
            snapshot.provider == .codex,
            snapshot.fetchedAt <= Date(),
            accepts(snapshot: snapshot, allowShapeChange: false)
        else { return }

        outageFailureEmitted = false
        recordAccepted(snapshot: snapshot)
        yield(.success(snapshot))
    }

    private func accepts(snapshot: UsageSnapshot, allowShapeChange: Bool) -> Bool {
        if let latestPublishedSnapshotFetchedAt,
            snapshot.fetchedAt <= latestPublishedSnapshotFetchedAt
        {
            return false
        }
        if !allowShapeChange,
            let latestPublishedSnapshotShape,
            latestPublishedSnapshotShape != snapshotShape(snapshot)
        {
            return false
        }
        return true
    }

    private func recordAccepted(snapshot: UsageSnapshot) {
        latestPublishedSnapshotFetchedAt = snapshot.fetchedAt
        latestPublishedSnapshotShape = snapshotShape(snapshot)
    }

    private func snapshotShape(_ snapshot: UsageSnapshot) -> SnapshotShape {
        SnapshotShape(
            hasFiveHour: snapshot.fiveHour != nil,
            hasWeekly: snapshot.weekly != nil
        )
    }

    private func publishFailureOnce(_ error: any Error) {
        guard !outageFailureEmitted else { return }
        outageFailureEmitted = true
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Codex 사용량을 가져오지 못했습니다.")
        let result = ProviderUsageResult.failure(UsageFailure(message: message))
        yield(result)
    }

    private func yield(_ result: ProviderUsageResult) {
        for subscriber in subscribers.values {
            guard lifecycle.isActive(subscriber.session) else { continue }
            subscriber.continuation.yield(result)
        }
    }

    private func stopMonitoringIsolated(generation: UInt64) {
        guard lifecycle.isCurrentStop(generation) else { return }
        activeSession = nil
        cancelMonitoringTasks()
        finishSubscribers(upTo: generation)
        disconnectClient()
        outageFailureEmitted = false
        lastPublishedReadID = nil
        latestPublishedSnapshotFetchedAt = nil
        latestPublishedSnapshotShape = nil
    }

    private func shutdownIsolated() {
        activeSession = nil
        cancelMonitoringTasks()
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
        disconnectClient()
        latestPublishedSnapshotFetchedAt = nil
        latestPublishedSnapshotShape = nil
    }

    private func cancelMonitoringTasks() {
        monitorTask?.cancel()
        monitorTask = nil
        monitorSleep?.task.cancel()
        monitorSleep = nil
        notificationCoalesceTask?.cancel()
        notificationCoalesceTask = nil
        localUpdateTask?.cancel()
        localUpdateTask = nil
        pendingImmediateRefresh = false
        pendingConnectionClosed = false
    }

    private func finishSubscribers(upTo generation: UInt64) {
        let ids = subscribers.compactMap { id, subscriber in
            subscriber.session <= generation ? id : nil
        }
        for id in ids {
            subscribers.removeValue(forKey: id)?.continuation.finish()
        }
    }

    private func disconnectClient() {
        pendingImmediateRefresh = false
        pendingConnectionClosed = false
        connectionOperation?.task.cancel()
        connectionOperation = nil
        readOperation?.task.cancel()
        readOperation = nil
        notificationTask?.cancel()
        notificationTask = nil
        notificationCoalesceTask?.cancel()
        notificationCoalesceTask = nil
        initializedClientID = nil
        let disconnected = client?.value
        client = nil
        disconnected?.shutdown()
    }

    private static func makeDefaultLocalUpdates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            let watcher = CodexUsageFileWatcher()
            watcher.start(continuation)
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    private static func emptyLocalUpdates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated static func makeSnapshot(
        from response: CodexRateLimitsResponse,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        let selectedRateLimits: CodexRateLimitsResponse.RateLimitSnapshot
        if let rateLimitsByLimitId = response.rateLimitsByLimitId,
            !rateLimitsByLimitId.isEmpty
        {
            if let codexRateLimits = rateLimitsByLimitId["codex"] {
                selectedRateLimits = codexRateLimits
            } else if response.rateLimits.limitId == "codex" {
                selectedRateLimits = response.rateLimits
            } else {
                throw UsageServiceError.currentWindowUnavailable("Codex")
            }
        } else {
            // Older app-server responses expose only this top-level snapshot.
            selectedRateLimits = response.rateLimits
        }

        let windows = selectedRateLimits.windows
        let fiveHour = windows.first(where: {
            $0.windowDurationMins == 300
        }).flatMap(makeWindow)
        let weekly = windows.first(where: {
            $0.windowDurationMins == 10_080
        }).flatMap(makeWindow)

        guard fiveHour != nil || weekly != nil else {
            throw UsageServiceError.currentWindowUnavailable("Codex")
        }

        return UsageSnapshot(
            provider: .codex,
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: fetchedAt
        )
    }

    nonisolated private static func makeWindow(
        _ window: CodexRateLimitsResponse.Window
    ) -> UsageLimitWindow? {
        guard let resetTimestamp = window.resetsAt else { return nil }
        return UsageLimitWindow(
            remainingFraction: 1 - (window.usedPercent / 100),
            resetAt: Date(timeIntervalSince1970: TimeInterval(resetTimestamp))
        )
    }
}
