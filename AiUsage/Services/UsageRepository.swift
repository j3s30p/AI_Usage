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
        await withTaskGroup(of: (UsageProvider, ProviderUsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await fetch(provider)
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

    private func fetch(_ provider: UsageProvider) async throws -> UsageSnapshot {
        switch provider {
        case .codex:
            try await codexProvider.fetchUsage()
        case .claude:
            try await claudeProvider.fetchUsage()
        }
    }
}
