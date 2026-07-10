import Foundation

enum ProviderUsageResult: Sendable, Equatable {
    case success(UsageSnapshot)
    case failure(UsageFailure)
}
