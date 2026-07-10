import Foundation

struct UsageRepository: UsageRepositoryProtocol, Sendable {
    private let codexProvider: CodexUsageProvider
    private let claudeProvider: ClaudeUsageProvider

    init(
        codexProvider: CodexUsageProvider = CodexUsageProvider(),
        claudeProvider: ClaudeUsageProvider = ClaudeUsageProvider()
    ) {
        self.codexProvider = codexProvider
        self.claudeProvider = claudeProvider
    }

    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult] {
        await fetchUsage(for: providers, claudeUsageMode: .statusLine)
    }

    func fetchUsage(
        for providers: Set<UsageProvider>,
        claudeUsageMode: ClaudeUsageMode
    ) async -> [UsageProvider: ProviderUsageResult] {
        await withTaskGroup(of: (UsageProvider, ProviderUsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await fetch(
                            provider,
                            claudeUsageMode: claudeUsageMode
                        )
                        return (provider, .success(snapshot))
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription
                            ?? "사용량을 가져오지 못했습니다."
                        return (provider, .failure(UsageFailure(message: message)))
                    }
                }
            }

            var results: [UsageProvider: ProviderUsageResult] = [:]
            for await (provider, result) in group {
                results[provider] = result
            }
            return results
        }
    }

    func updates(
        for providers: Set<UsageProvider>,
        refreshInterval: Duration
    ) -> AsyncStream<ProviderUsageUpdate> {
        guard providers.contains(.codex) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await result in codexProvider.updates(
                    refreshInterval: refreshInterval
                ) {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        ProviderUsageUpdate(provider: .codex, result: result)
                    )
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    func stopMonitoring(providers: Set<UsageProvider>) {
        guard providers.contains(.codex) else { return }
        codexProvider.stopMonitoring()
    }

    func shutdown() {
        codexProvider.shutdown()
    }

    private func fetch(
        _ provider: UsageProvider,
        claudeUsageMode: ClaudeUsageMode
    ) async throws -> UsageSnapshot {
        switch provider {
        case .codex:
            try await codexProvider.fetchUsage()
        case .claude:
            try await claudeProvider.fetchUsage(mode: claudeUsageMode)
        }
    }
}
