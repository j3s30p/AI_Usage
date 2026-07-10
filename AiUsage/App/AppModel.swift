import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var states: [UsageProvider: ProviderLoadState]
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    @ObservationIgnored private let repository: any UsageRepositoryProtocol
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var activeRefreshCount = 0

    init(repository: any UsageRepositoryProtocol) {
        self.repository = repository
        states = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, .idle) }
        )
    }

    func state(for provider: UsageProvider) -> ProviderLoadState {
        states[provider] ?? .idle
    }

    func refresh(providers: Set<UsageProvider>) async {
        guard !providers.isEmpty else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        activeRefreshCount += 1
        isRefreshing = true

        for provider in providers {
            states[provider] = .loading(previous: state(for: provider).snapshot)
        }

        await withTaskGroup(of: (UsageProvider, ProviderUsageResult?).self) { group in
            for provider in providers {
                group.addTask { [repository] in
                    let results = await repository.fetchUsage(for: [provider])
                    return (provider, results[provider])
                }
            }

            for await (provider, result) in group {
                guard !Task.isCancelled, generation == refreshGeneration else { continue }

                let previous = state(for: provider).snapshot
                switch result {
                case .success(let snapshot):
                    states[provider] = .loaded(snapshot)
                case .failure(let failure):
                    states[provider] = .failed(failure, previous: previous)
                case nil:
                    states[provider] = .failed(
                        UsageFailure(message: "사용량 응답을 받지 못했습니다."),
                        previous: previous
                    )
                }
                lastRefreshAt = .now
            }
        }

        activeRefreshCount -= 1
        isRefreshing = activeRefreshCount > 0
    }

    func monitor(providers: Set<UsageProvider>) async {
        guard !providers.isEmpty else { return }

        while !Task.isCancelled {
            await refresh(providers: providers)
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
        }
    }
}
