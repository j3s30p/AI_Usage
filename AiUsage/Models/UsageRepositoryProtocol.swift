import Foundation

protocol UsageRepositoryProtocol: Sendable {
    func fetchUsage(
        for providers: Set<UsageProvider>
    ) async -> [UsageProvider: ProviderUsageResult]
}
