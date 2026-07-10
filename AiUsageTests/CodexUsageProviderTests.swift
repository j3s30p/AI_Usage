import Foundation
import XCTest
@testable import AiUsage

final class CodexUsageProviderTests: XCTestCase {
    func testMonitoringReusesOneClientForInitialAndPeriodicReads() async throws {
        let client = FakeCodexAppServerClient(responses: [.success(makeResponse(used: 20))])
        let factory = FakeCodexClientFactory(clients: [client])
        let provider = CodexUsageProvider(
            clientFactory: { try factory.makeClient() },
            reconnectBackoff: [.milliseconds(10)]
        )
        let recorder = ProviderResultRecorder()
        let consumer = consume(
            provider.updates(refreshInterval: .milliseconds(25)),
            into: recorder
        )

        let receivedPeriodicUpdate = await waitUntil { recorder.successCount >= 2 }
        XCTAssertTrue(receivedPeriodicUpdate)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(client.initializeCount, 1)
        XCTAssertGreaterThanOrEqual(client.fetchCount, 2)

        consumer.cancel()
        provider.stopMonitoring()
        let stoppedClient = await waitUntil { client.shutdownCount == 1 }
        XCTAssertTrue(stoppedClient)
    }

    func testRateLimitNotificationsCoalesceIntoOneAuthoritativeRead() async throws {
        let client = FakeCodexAppServerClient(responses: [.success(makeResponse(used: 10))])
        let factory = FakeCodexClientFactory(clients: [client])
        let provider = CodexUsageProvider(
            clientFactory: { try factory.makeClient() },
            reconnectBackoff: [.milliseconds(10)]
        )
        let recorder = ProviderResultRecorder()
        let consumer = consume(
            provider.updates(refreshInterval: .seconds(5)),
            into: recorder
        )
        let receivedInitialRead = await waitUntil { client.fetchCount == 1 }
        XCTAssertTrue(receivedInitialRead)

        for _ in 0..<8 {
            client.sendRateLimitsUpdated()
        }

        let receivedNotificationRead = await waitUntil { client.fetchCount == 2 }
        XCTAssertTrue(receivedNotificationRead)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(client.fetchCount, 2)
        XCTAssertEqual(recorder.successCount, 2)
        XCTAssertEqual(factory.creationCount, 1)

        consumer.cancel()
        provider.stopMonitoring()
    }

    func testReconnectEmitsOnlyOneFailurePerOutageAndClearsItOnSuccess() async throws {
        let first = FakeCodexAppServerClient(responses: [.failure(TestFailure.offline)])
        let second = FakeCodexAppServerClient(responses: [.failure(TestFailure.offline)])
        let third = FakeCodexAppServerClient(responses: [
            .success(makeResponse(used: 30)),
            .failure(TestFailure.offline),
        ])
        let recovered = FakeCodexAppServerClient(responses: [.success(makeResponse(used: 40))])
        let factory = FakeCodexClientFactory(clients: [first, second, third, recovered])
        let provider = CodexUsageProvider(
            clientFactory: { try factory.makeClient() },
            reconnectBackoff: [.milliseconds(5), .milliseconds(10)]
        )
        let recorder = ProviderResultRecorder()
        let consumer = consume(
            provider.updates(refreshInterval: .milliseconds(20)),
            into: recorder
        )

        let recoveredTwice = await waitUntil(timeoutIterations: 400) {
            recorder.failureCount == 2 && recorder.successCount >= 2
        }
        XCTAssertTrue(recoveredTwice)
        XCTAssertEqual(recorder.failureCount, 2)
        XCTAssertGreaterThanOrEqual(factory.creationCount, 4)
        XCTAssertEqual(first.shutdownCount, 1)
        XCTAssertEqual(second.shutdownCount, 1)
        XCTAssertEqual(third.shutdownCount, 1)

        consumer.cancel()
        provider.stopMonitoring()
    }

    func testConcurrentManualFetchesShareOneConnectionAndOneRead() async throws {
        let client = FakeCodexAppServerClient(
            responses: [.success(makeResponse(used: 25))],
            fetchDelay: .milliseconds(60)
        )
        let factory = FakeCodexClientFactory(clients: [client])
        let provider = CodexUsageProvider(
            clientFactory: { try factory.makeClient() },
            reconnectBackoff: [.milliseconds(10)]
        )

        async let first = provider.fetchUsage()
        async let second = provider.fetchUsage()
        async let third = provider.fetchUsage()
        let snapshots = try await [first, second, third]

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(client.initializeCount, 1)
        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertEqual(Set(snapshots.map(\.remainingPercentage)), [75])
        provider.shutdown()
    }

    func testInitialFullReadsSelectNormalSnapshotWithLatestReset() async throws {
        let client = FakeCodexAppServerClient(responses: [
            .success(makeResponse(used: 0, primaryResetAt: 1_900_000_000)),
            .success(makeResponse(used: 0, primaryResetAt: 1_900_000_000)),
            .success(makeResponse(used: 23, primaryResetAt: 1_900_003_000)),
        ])
        let provider = CodexUsageProvider(clientFactory: { client })

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.remainingPercentage, 77)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_900_003_000)
        XCTAssertEqual(client.fetchCount, 3)
        provider.shutdown()
    }

    func testInitialConfirmedFullUsageRemainsFull() async throws {
        let client = FakeCodexAppServerClient(responses: [
            .success(makeResponse(used: 0, primaryResetAt: 1_900_000_000)),
            .success(makeResponse(used: 0, primaryResetAt: 1_900_000_100)),
            .success(makeResponse(used: 0, primaryResetAt: 1_900_000_200)),
        ])
        let provider = CodexUsageProvider(clientFactory: { client })

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.remainingPercentage, 100)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_900_000_200)
        XCTAssertEqual(client.fetchCount, 3)
        provider.shutdown()
    }

    func testInitialConfirmationFailureKeepsFirstValidFullSnapshot() async throws {
        let initial = makeResponse(used: 0, primaryResetAt: 1_900_000_000)
        let client = FakeCodexAppServerClient(responses: [
            .success(initial),
            .failure(TestFailure.offline),
            .failure(TestFailure.offline),
        ])
        let provider = CodexUsageProvider(clientFactory: { client })

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.remainingPercentage, 100)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_900_000_000)
        XCTAssertEqual(client.fetchCount, 3)
        provider.shutdown()
    }

    func testInitialNonFullReadDoesNotIssueConfirmationReads() async throws {
        let client = FakeCodexAppServerClient(responses: [
            .success(makeResponse(used: 25)),
        ])
        let provider = CodexUsageProvider(clientFactory: { client })

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.remainingPercentage, 75)
        XCTAssertEqual(client.fetchCount, 1)
        provider.shutdown()
    }

    func testStopPreventsOldReconnectButLaterSubscriptionCanStartAgain() async throws {
        let offline = FakeCodexAppServerClient(responses: [.failure(TestFailure.offline)])
        let recovered = FakeCodexAppServerClient(responses: [.success(makeResponse(used: 15))])
        let factory = FakeCodexClientFactory(clients: [offline, recovered])
        let provider = CodexUsageProvider(
            clientFactory: { try factory.makeClient() },
            reconnectBackoff: [.milliseconds(200)]
        )
        let firstRecorder = ProviderResultRecorder()
        let firstConsumer = consume(
            provider.updates(refreshInterval: .seconds(5)),
            into: firstRecorder
        )
        let receivedFailure = await waitUntil { firstRecorder.failureCount == 1 }
        XCTAssertTrue(receivedFailure)

        provider.stopMonitoring()
        firstConsumer.cancel()
        let creationCountAtStop = factory.creationCount
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(factory.creationCount, creationCountAtStop)

        let secondRecorder = ProviderResultRecorder()
        let secondConsumer = consume(
            provider.updates(refreshInterval: .seconds(5)),
            into: secondRecorder
        )
        let receivedRecovery = await waitUntil { secondRecorder.successCount == 1 }
        XCTAssertTrue(receivedRecovery)
        XCTAssertEqual(factory.creationCount, creationCountAtStop + 1)

        secondConsumer.cancel()
        provider.shutdown()
    }

    private func consume(
        _ stream: AsyncStream<ProviderUsageResult>,
        into recorder: ProviderResultRecorder
    ) -> Task<Void, Never> {
        Task {
            for await result in stream {
                guard !Task.isCancelled else { return }
                recorder.append(result)
            }
        }
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private enum TestFailure: Error, LocalizedError {
    case offline

    var errorDescription: String? { "테스트 연결 실패" }
}

private final class ProviderResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProviderUsageResult] = []

    var successCount: Int {
        lock.withLock { results.filter { if case .success = $0 { true } else { false } }.count }
    }

    var failureCount: Int {
        lock.withLock { results.filter { if case .failure = $0 { true } else { false } }.count }
    }

    func append(_ result: ProviderUsageResult) {
        lock.withLock { results.append(result) }
    }
}

private final class FakeCodexClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [FakeCodexAppServerClient]
    private var storedCreationCount = 0

    init(clients: [FakeCodexAppServerClient]) {
        self.clients = clients
    }

    var creationCount: Int {
        lock.withLock { storedCreationCount }
    }

    func makeClient() throws -> any CodexAppServerServing {
        try lock.withLock {
            storedCreationCount += 1
            guard !clients.isEmpty else { throw TestFailure.offline }
            if clients.count == 1 { return clients[0] }
            return clients.removeFirst()
        }
    }
}

private final class FakeCodexAppServerClient: CodexAppServerServing, @unchecked Sendable {
    private let lock = NSLock()
    private let notificationContinuation: AsyncStream<CodexAppServerNotification>.Continuation
    let notifications: AsyncStream<CodexAppServerNotification>
    private var responses: [Result<CodexRateLimitsResponse, any Error>]
    private let fetchDelay: Duration
    private var running = true
    private var storedInitializeCount = 0
    private var storedFetchCount = 0
    private var storedShutdownCount = 0

    init(
        responses: [Result<CodexRateLimitsResponse, any Error>],
        fetchDelay: Duration = .zero
    ) {
        let stream = AsyncStream<CodexAppServerNotification>.makeStream()
        notifications = stream.stream
        notificationContinuation = stream.continuation
        self.responses = responses
        self.fetchDelay = fetchDelay
    }

    var isRunning: Bool { lock.withLock { running } }
    var initializeCount: Int { lock.withLock { storedInitializeCount } }
    var fetchCount: Int { lock.withLock { storedFetchCount } }
    var shutdownCount: Int { lock.withLock { storedShutdownCount } }

    func initialize() async throws {
        try lock.withLock {
            guard running else { throw TestFailure.offline }
            storedInitializeCount += 1
        }
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        let response: Result<CodexRateLimitsResponse, any Error> = try lock.withLock {
            guard running else { throw TestFailure.offline }
            storedFetchCount += 1
            guard let first = responses.first else { throw TestFailure.offline }
            if responses.count > 1 { responses.removeFirst() }
            return first
        }
        if fetchDelay > .zero {
            try await Task.sleep(for: fetchDelay)
        }
        return try response.get()
    }

    func shutdown() {
        let shouldFinish = lock.withLock {
            guard running else { return false }
            running = false
            storedShutdownCount += 1
            return true
        }
        if shouldFinish { notificationContinuation.finish() }
    }

    func sendRateLimitsUpdated() {
        notificationContinuation.yield(
            CodexAppServerNotification(
                method: "account/rateLimits/updated",
                rawData: Data("{}".utf8)
            )
        )
    }
}

private func makeResponse(
    used: Double,
    primaryResetAt: Int64 = 1_900_000_000
) -> CodexRateLimitsResponse {
    CodexRateLimitsResponse(
        rateLimits: .init(
            primary: .init(
                usedPercent: used,
                windowDurationMins: 300,
                resetsAt: primaryResetAt
            ),
            secondary: .init(
                usedPercent: used / 2,
                windowDurationMins: 10_080,
                resetsAt: 1_900_500_000
            )
        ),
        rateLimitsByLimitId: nil
    )
}
