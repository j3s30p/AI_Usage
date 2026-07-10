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

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(model: model, preferences: preferences)
        observePreferences()
        observeModel()
        restartMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
    }

    private func restartMonitor() {
        monitorTask?.cancel()
        let providers = preferences.enabledProviders
        monitoredProviders = providers
        menuBarController?.updateStatusItem()

        guard !providers.isEmpty else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await model.monitor(providers: providers)
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.showCodex
            _ = preferences.showClaude
            _ = preferences.showPercentage
            _ = preferences.providerDisplayMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                menuBarController?.updateStatusItem()
                if preferences.enabledProviders != monitoredProviders {
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
