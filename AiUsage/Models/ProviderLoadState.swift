import Foundation

enum ProviderLoadState: Sendable, Equatable {
    case idle
    case loading(previous: UsageSnapshot?)
    case loaded(UsageSnapshot)
    case failed(UsageFailure, previous: UsageSnapshot?)

    var snapshot: UsageSnapshot? {
        switch self {
        case .idle:
            nil
        case .loading(let previous), .failed(_, let previous):
            previous
        case .loaded(let snapshot):
            snapshot
        }
    }

    var failure: UsageFailure? {
        guard case .failed(let failure, _) = self else { return nil }
        return failure
    }

    var isLoading: Bool {
        guard case .loading = self else { return false }
        return true
    }
}
