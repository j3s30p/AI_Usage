import Foundation
import XCTest
@testable import AiUsage

@MainActor
final class AppModelTests: XCTestCase {
    func testAppModelRetainsLastSuccessfulSnapshotOnFailure() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(
            provider: .codex,
            remainingFraction: 0.72,
            resetAt: now.addingTimeInterval(3_600),
            fetchedAt: now
        )
        let repository = SequencedUsageRepository(responses: [
            [.codex: .success(snapshot)],
            [.codex: .failure(UsageFailure(message: "연결 실패"))],
        ])
        let model = AppModel(repository: repository)

        await model.refresh(providers: [.codex])
        XCTAssertEqual(model.state(for: .codex).snapshot, snapshot)

        await model.refresh(providers: [.codex])
        XCTAssertEqual(model.state(for: .codex).snapshot, snapshot)
        XCTAssertEqual(model.state(for: .codex).failure?.message, "연결 실패")
    }

    func testRefreshDoesNotReplaceNewerSnapshotWithOlderFallback() async {
        let now = Date(timeIntervalSince1970: 15_000)
        let current = makeSnapshot(
            provider: .claude,
            remainingFraction: 0.42,
            fetchedAt: now
        )
        let olderFallback = makeSnapshot(
            provider: .claude,
            remainingFraction: 0.83,
            fetchedAt: now.addingTimeInterval(-60)
        )
        let repository = SequencedUsageRepository(responses: [
            [.claude: .success(current)],
            [.claude: .success(olderFallback)],
        ])
        let model = AppModel(repository: repository)

        await model.refresh(providers: [.claude])
        await model.refresh(providers: [.claude])

        XCTAssertEqual(model.state(for: .claude).snapshot, current)
    }

    func testRefreshPublishesFastProviderWithoutWaitingForSlowProvider() async {
        let now = Date(timeIntervalSince1970: 20_000)
        let codex = UsageSnapshot(
            provider: .codex,
            remainingFraction: 0.23,
            resetAt: now.addingTimeInterval(3_600),
            fetchedAt: now
        )
        let claude = UsageSnapshot(
            provider: .claude,
            remainingFraction: 0.48,
            resetAt: now.addingTimeInterval(3_600),
            fetchedAt: now
        )
        let gate = AsyncGate()
        let repository = DelayedClaudeRepository(codex: codex, claude: claude, gate: gate)
        let model = AppModel(repository: repository)

        let refreshTask = Task {
            await model.refresh(providers: [.codex, .claude])
        }

        for _ in 0..<200 where model.state(for: .codex).snapshot == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.state(for: .codex).snapshot, codex)
        XCTAssertNil(model.state(for: .claude).snapshot)
        await gate.open()
        await refreshTask.value
        XCTAssertEqual(model.state(for: .claude).snapshot, claude)
    }

    func testMonitorAppliesCodexPushWithoutMarkingRefreshInProgress() async {
        let now = Date(timeIntervalSince1970: 30_000)
        let initial = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.72,
            fetchedAt: now
        )
        let pushed = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.61,
            fetchedAt: now.addingTimeInterval(1)
        )
        let repository = StreamingUsageRepository(responses: [])
        repository.send(.success(initial))
        let model = AppModel(repository: repository)
        let monitorTask = Task {
            await model.monitor(
                providers: [.codex],
                refreshInterval: .seconds(60)
            )
        }

        let receivedInitial = await waitUntil {
            model.state(for: .codex).snapshot == initial
        }
        XCTAssertTrue(receivedInitial)
        repository.send(.success(pushed))
        let receivedPush = await waitUntil {
            model.state(for: .codex).snapshot == pushed
        }
        XCTAssertTrue(receivedPush)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(repository.fetchCount, 0)
        XCTAssertEqual(repository.lastUpdateRefreshInterval, .seconds(60))

        monitorTask.cancel()
        repository.finishUpdates()
        await monitorTask.value
    }

    func testMonitorIgnoresCodexPushOlderThanCurrentSnapshot() async {
        let now = Date(timeIntervalSince1970: 40_000)
        let current = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.52,
            fetchedAt: now
        )
        let older = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.81,
            fetchedAt: now.addingTimeInterval(-1)
        )
        let repository = StreamingUsageRepository(responses: [])
        repository.send(.success(current))
        let model = AppModel(repository: repository)
        let monitorTask = Task {
            await model.monitor(
                providers: [.codex],
                refreshInterval: .seconds(60)
            )
        }

        let receivedInitial = await waitUntil {
            model.state(for: .codex).snapshot == current
        }
        XCTAssertTrue(receivedInitial)
        repository.send(.success(older))
        repository.send(.failure(UsageFailure(message: "업데이트 확인")))
        let processedFollowingUpdate = await waitUntil {
            model.state(for: .codex).failure?.message == "업데이트 확인"
        }
        XCTAssertTrue(processedFollowingUpdate)
        XCTAssertEqual(model.state(for: .codex).snapshot, current)

        monitorTask.cancel()
        repository.finishUpdates()
        await monitorTask.value
    }

    func testMonitorRetainsCodexSnapshotWhenPushReportsFailure() async {
        let now = Date(timeIntervalSince1970: 50_000)
        let current = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.42,
            fetchedAt: now
        )
        let repository = StreamingUsageRepository(responses: [])
        repository.send(.success(current))
        let model = AppModel(repository: repository)
        let monitorTask = Task {
            await model.monitor(
                providers: [.codex],
                refreshInterval: .seconds(60)
            )
        }

        let receivedInitial = await waitUntil {
            model.state(for: .codex).snapshot == current
        }
        XCTAssertTrue(receivedInitial)
        repository.send(.failure(UsageFailure(message: "연결 끊김")))
        let receivedFailure = await waitUntil {
            model.state(for: .codex).failure?.message == "연결 끊김"
        }
        XCTAssertTrue(receivedFailure)
        XCTAssertEqual(model.state(for: .codex).snapshot, current)

        monitorTask.cancel()
        repository.finishUpdates()
        await monitorTask.value
    }

    func testMonitorKeepsPollingAsFallback() async {
        let now = Date(timeIntervalSince1970: 60_000)
        let initial = makeSnapshot(
            provider: .claude,
            remainingFraction: 0.32,
            fetchedAt: now
        )
        let fallback = makeSnapshot(
            provider: .claude,
            remainingFraction: 0.21,
            fetchedAt: now.addingTimeInterval(1)
        )
        let repository = StreamingUsageRepository(responses: [
            [.claude: .success(initial)],
            [.claude: .success(fallback)],
        ])
        let model = AppModel(repository: repository)
        let monitorTask = Task {
            await model.monitor(
                providers: [.claude],
                refreshInterval: .milliseconds(10)
            )
        }

        let receivedFallback = await waitUntil {
            model.state(for: .claude).snapshot == fallback
        }
        XCTAssertTrue(receivedFallback)
        XCTAssertGreaterThanOrEqual(repository.fetchCount, 2)
        XCTAssertNil(repository.lastUpdateRefreshInterval)

        monitorTask.cancel()
        repository.finishUpdates()
        await monitorTask.value
    }

    func testModelForwardsStopAndShutdownToRepository() {
        let repository = StreamingUsageRepository(responses: [])
        let model = AppModel(repository: repository)

        model.stopMonitoring(providers: [.codex])
        model.shutdown()

        XCTAssertEqual(repository.stoppedProviders, [.codex])
        XCTAssertTrue(repository.didShutdown)
    }

    func testCancellingMonitorEndsWithoutFinishingUpdateProducer() async {
        let now = Date(timeIntervalSince1970: 70_000)
        let initial = makeSnapshot(
            provider: .codex,
            remainingFraction: 0.11,
            fetchedAt: now
        )
        let repository = StreamingUsageRepository(responses: [])
        repository.send(.success(initial))
        let model = AppModel(repository: repository)
        let monitorFinished = expectation(description: "monitor task finished")
        let monitorTask = Task {
            await model.monitor(
                providers: [.codex],
                refreshInterval: .seconds(60)
            )
            monitorFinished.fulfill()
        }

        let receivedInitial = await waitUntil {
            model.state(for: .codex).snapshot == initial
        }
        XCTAssertTrue(receivedInitial)
        monitorTask.cancel()
        await fulfillment(of: [monitorFinished], timeout: 1)

        repository.finishUpdates()
        await monitorTask.value
    }

    private func makeSnapshot(
        provider: UsageProvider,
        remainingFraction: Double,
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            remainingFraction: remainingFraction,
            resetAt: fetchedAt.addingTimeInterval(3_600),
            fetchedAt: fetchedAt
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private final class StreamingUsageRepository: UsageRepositoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[UsageProvider: ProviderUsageResult]]
    private var storedFetchCount = 0
    private var storedStoppedProviders: Set<UsageProvider> = []
    private var storedDidShutdown = false
    private var storedLastUpdateRefreshInterval: Duration?
    private let updateStream: AsyncStream<ProviderUsageUpdate>
    private let updateContinuation: AsyncStream<ProviderUsageUpdate>.Continuation

    init(responses: [[UsageProvider: ProviderUsageResult]]) {
        self.responses = responses
        let stream = AsyncStream<ProviderUsageUpdate>.makeStream()
        updateStream = stream.stream
        updateContinuation = stream.continuation
    }

    var fetchCount: Int {
        lock.withLock { storedFetchCount }
    }

    var stoppedProviders: Set<UsageProvider> {
        lock.withLock { storedStoppedProviders }
    }

    var didShutdown: Bool {
        lock.withLock { storedDidShutdown }
    }

    var lastUpdateRefreshInterval: Duration? {
        lock.withLock { storedLastUpdateRefreshInterval }
    }

    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult] {
        lock.withLock {
            storedFetchCount += 1
            guard !responses.isEmpty else { return [:] }
            return responses.removeFirst().filter { providers.contains($0.key) }
        }
    }

    func updates(
        for providers: Set<UsageProvider>,
        refreshInterval: Duration
    ) -> AsyncStream<ProviderUsageUpdate> {
        lock.withLock {
            storedLastUpdateRefreshInterval = refreshInterval
        }
        guard providers.contains(.codex) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return updateStream
    }

    func stopMonitoring(providers: Set<UsageProvider>) {
        lock.withLock {
            storedStoppedProviders.formUnion(providers)
        }
    }

    func shutdown() {
        lock.withLock {
            storedDidShutdown = true
        }
        updateContinuation.finish()
    }

    func send(_ result: ProviderUsageResult) {
        updateContinuation.yield(
            ProviderUsageUpdate(provider: .codex, result: result)
        )
    }

    func finishUpdates() {
        updateContinuation.finish()
    }
}

private actor SequencedUsageRepository: UsageRepositoryProtocol {
    private var responses: [[UsageProvider: ProviderUsageResult]]

    init(responses: [[UsageProvider: ProviderUsageResult]]) {
        self.responses = responses
    }

    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult] {
        guard !responses.isEmpty else { return [:] }
        let response = responses.removeFirst()
        return response.filter { providers.contains($0.key) }
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

private actor DelayedClaudeRepository: UsageRepositoryProtocol {
    let codex: UsageSnapshot
    let claude: UsageSnapshot
    let gate: AsyncGate

    init(codex: UsageSnapshot, claude: UsageSnapshot, gate: AsyncGate) {
        self.codex = codex
        self.claude = claude
        self.gate = gate
    }

    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult] {
        if providers.contains(.claude) {
            await gate.wait()
            return [.claude: .success(claude)]
        }
        if providers.contains(.codex) {
            return [.codex: .success(codex)]
        }
        return [:]
    }
}
