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
