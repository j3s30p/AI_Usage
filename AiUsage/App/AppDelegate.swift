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

    private func restartMonitor() {
        let previousTask = monitorTask
        previousTask?.cancel()
        let providers = preferences.enabledProviders
        let refreshInterval = preferences.refreshInterval
        let removedProviders = monitoredProviders.subtracting(providers)
        monitoredProviders = providers
        monitoredRefreshInterval = refreshInterval
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
                refreshInterval: refreshInterval.duration
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                menuBarController?.updateStatusItem()
                if preferences.enabledProviders != monitoredProviders
                    || preferences.refreshInterval != monitoredRefreshInterval {
                    restartMonitor()
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
