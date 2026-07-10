import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(repository: UsageRepository())
    let preferences = AppPreferences()

    private var menuBarController: MenuBarController?
    private var monitorTask: Task<Void, Never>?
    private var monitoredProviders: Set<UsageProvider> = []
    private var monitoredRefreshInterval: UsageRefreshInterval?
    private var monitoredClaudeUsageMode: ClaudeUsageMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        menuBarController = MenuBarController(model: model, preferences: preferences)
        observePreferences()
        observeModel()
        restartMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
        model.shutdown()
    }

    func connectClaudeKeychainFromUserAction() async throws {
        let result = await ClaudeOAuthUserInitiatedKeychainAccess()
            .requestAccessFromUserAction()
        guard result == .available else {
            throw ClaudeKeychainConnectionError(result: result)
        }

        await model.refresh(
            providers: [.claude],
            claudeUsageMode: .oauth
        )
    }

    private func restartMonitor() {
        let previousTask = monitorTask
        previousTask?.cancel()
        let providers = preferences.enabledProviders
        let refreshInterval = preferences.refreshInterval
        let claudeUsageMode = preferences.claudeUsageMode
        let removedProviders = monitoredProviders.subtracting(providers)
        monitoredProviders = providers
        monitoredRefreshInterval = refreshInterval
        monitoredClaudeUsageMode = claudeUsageMode
        model.selectClaudeUsageMode(claudeUsageMode)
        model.stopMonitoring(providers: removedProviders)
        menuBarController?.updateStatusItem()

        guard !providers.isEmpty else {
            monitorTask = nil
            return
        }

        monitorTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled, let self else { return }
            await model.monitor(
                providers: providers,
                refreshInterval: refreshInterval.duration,
                claudeUsageMode: claudeUsageMode
            )
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.showCodex
            _ = preferences.showClaude
            _ = preferences.showPercentage
            _ = preferences.providerDisplayMode
            _ = preferences.refreshInterval
            _ = preferences.claudeUsageMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let shouldRestartMonitor = preferences.enabledProviders != monitoredProviders
                    || preferences.refreshInterval != monitoredRefreshInterval
                    || preferences.claudeUsageMode != monitoredClaudeUsageMode
                if shouldRestartMonitor {
                    restartMonitor()
                } else {
                    menuBarController?.updateStatusItem()
                }
                observePreferences()
            }
        }
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.states
            _ = model.isRefreshing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                menuBarController?.updateStatusItem()
                observeModel()
            }
        }
    }
}

private struct ClaudeKeychainConnectionError: LocalizedError {
    let result: ClaudeOAuthUserInitiatedAccessResult

    var errorDescription: String? {
        switch result {
        case .available:
            nil
        case .notFound:
            "Claude Code Keychain 항목을 찾지 못했습니다."
        case .denied:
            "Claude Code Keychain 접근이 거부되었습니다."
        case .cancelled:
            "Claude Code Keychain 연결이 취소되었습니다."
        case .invalidCredentials:
            "Claude Code Keychain 인증 정보를 확인할 수 없습니다."
        case .expired:
            "Claude Code Keychain 인증 정보가 만료되었습니다."
        case .unavailable:
            "Claude Code Keychain을 사용할 수 없습니다."
        }
    }
}
