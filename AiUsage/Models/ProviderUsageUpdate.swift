import Foundation

struct ProviderUsageUpdate: Sendable, Equatable {
    let provider: UsageProvider
    let result: ProviderUsageResult
}
