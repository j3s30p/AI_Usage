import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let codexResetRegressionTolerance: TimeInterval = 60

    private(set) var states: [UsageProvider: ProviderLoadState]
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    @ObservationIgnored private let repository: any UsageRepositoryProtocol
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var activeRefreshCount = 0
    @ObservationIgnored private var activeClaudeUsageMode: ClaudeUsageMode?

    init(repository: any UsageRepositoryProtocol) {
        self.repository = repository
        states = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, .idle) }
        )
    }

    func state(for provider: UsageProvider) -> ProviderLoadState {
        states[provider] ?? .idle
    }

    func selectClaudeUsageMode(_ mode: ClaudeUsageMode) {
        guard activeClaudeUsageMode != mode else { return }
        if activeClaudeUsageMode != nil {
            states[.claude] = .idle
            refreshGeneration += 1
        }
        activeClaudeUsageMode = mode
    }

    func refresh(
        providers: Set<UsageProvider>,
        claudeUsageMode: ClaudeUsageMode = .statusLine
    ) async {
        guard !providers.isEmpty else { return }

        if providers.contains(.claude) {
            // A newer snapshot from another source must not mask the first
            // result (or failure) from the newly selected Claude mode.
            selectClaudeUsageMode(claudeUsageMode)
        }

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
                    let results = await repository.fetchUsage(
                        for: [provider],
                        claudeUsageMode: claudeUsageMode
                    )
                    return (provider, results[provider])
                }
            }

            for await (provider, result) in group {
                guard !Task.isCancelled, generation == refreshGeneration else { continue }

                let previous = state(for: provider).snapshot
                switch result {
                case .success(let snapshot):
                    applySuccessfulSnapshot(
                        snapshot,
                        for: provider,
                        previous: previous
                    )
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

    func monitor(
        providers: Set<UsageProvider>,
        refreshInterval: Duration = .seconds(180),
        claudeUsageMode: ClaudeUsageMode = .statusLine
    ) async {
        guard !providers.isEmpty else { return }

        let periodicallyFetchedProviders = providers.subtracting([.codex])
        await withTaskGroup(of: Void.self) { group in
            if !periodicallyFetchedProviders.isEmpty {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.refresh(
                        providers: periodicallyFetchedProviders,
                        claudeUsageMode: claudeUsageMode
                    )

                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: refreshInterval)
                        } catch {
                            return
                        }

                        guard !Task.isCancelled else { return }
                        await self.refresh(
                            providers: periodicallyFetchedProviders,
                            claudeUsageMode: claudeUsageMode
                        )
                    }
                }
            }

            if providers.contains(.codex) {
                group.addTask { [weak self, repository] in
                    let updates = repository.updates(
                        for: [.codex],
                        refreshInterval: refreshInterval
                    )
                    for await update in updates {
                        guard !Task.isCancelled, let self else { return }
                        await self.apply(update)
                    }
                }
            }

            await group.waitForAll()
        }
    }

    func stopMonitoring(providers: Set<UsageProvider>) {
        repository.stopMonitoring(providers: providers)
    }

    func shutdown() {
        repository.shutdown()
    }

    private func apply(_ update: ProviderUsageUpdate) {
        let previous = state(for: update.provider).snapshot
        switch update.result {
        case .success(let snapshot):
            applySuccessfulSnapshot(
                snapshot,
                for: update.provider,
                previous: previous
            )
        case .failure(let failure):
            states[update.provider] = .failed(failure, previous: previous)
        }
        lastRefreshAt = .now
    }

    private func applySuccessfulSnapshot(
        _ candidate: UsageSnapshot,
        for provider: UsageProvider,
        previous: UsageSnapshot?
    ) {
        guard let previous else {
            states[provider] = .loaded(candidate)
            return
        }

        guard candidate.fetchedAt >= previous.fetchedAt,
            !shouldRetainPreviousCodexSnapshot(
                previous,
                insteadOf: candidate,
                for: provider
            )
        else {
            states[provider] = .loaded(previous)
            return
        }

        states[provider] = .loaded(candidate)
    }

    private func shouldRetainPreviousCodexSnapshot(
        _ previous: UsageSnapshot,
        insteadOf candidate: UsageSnapshot,
        for provider: UsageProvider
    ) -> Bool {
        guard provider == .codex else { return false }

        if let previousFiveHour = previous.fiveHour,
            let candidateFiveHour = candidate.fiveHour,
            isRegressiveActiveWindow(
                previous: previousFiveHour,
                candidate: candidateFiveHour,
                at: candidate.fetchedAt
            )
        {
            return true
        }

        guard let previousWeekly = previous.weekly,
            let candidateWeekly = candidate.weekly
        else { return false }

        return isRegressiveActiveWindow(
            previous: previousWeekly,
            candidate: candidateWeekly,
            at: candidate.fetchedAt
        )
    }

    private func isRegressiveActiveWindow(
        previous: UsageLimitWindow,
        candidate: UsageLimitWindow,
        at fetchedAt: Date
    ) -> Bool {
        guard previous.resetAt > fetchedAt,
            candidate.remainingFraction > previous.remainingFraction
        else { return false }

        return previous.resetAt.timeIntervalSince(candidate.resetAt)
            > Self.codexResetRegressionTolerance
    }
}
