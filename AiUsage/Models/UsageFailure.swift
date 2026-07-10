import Foundation

struct UsageFailure: Error, LocalizedError, Sendable, Codable, Equatable {
    let message: String

    var errorDescription: String? { message }
}
