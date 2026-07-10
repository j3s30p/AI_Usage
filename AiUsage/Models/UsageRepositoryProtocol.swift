import Foundation

protocol UsageRepositoryProtocol: Sendable {
    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult]

    func updates(
        for providers: Set<UsageProvider>,
        refreshInterval: Duration
    ) -> AsyncStream<ProviderUsageUpdate>

    func stopMonitoring(providers: Set<UsageProvider>)
    func shutdown()
}

extension UsageRepositoryProtocol {
    func updates(
        for providers: Set<UsageProvider>,
        refreshInterval: Duration
    ) -> AsyncStream<ProviderUsageUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopMonitoring(providers: Set<UsageProvider>) {}
    func shutdown() {}
}
