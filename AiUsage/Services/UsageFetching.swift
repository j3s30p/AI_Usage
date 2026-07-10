import Foundation

protocol UsageFetching: Sendable {
    var provider: UsageProvider { get }
    func fetchUsage() async throws -> UsageSnapshot
}
