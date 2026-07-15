import AppKit
import Observation
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(repository: UsageRepository())
    let preferences = AppPreferences()
    let launchAtLoginController = LaunchAtLoginController()
    let statusLineSettingsModel = ClaudeStatusLineSettingsModel()
    let updateStatusModel = UpdateStatusModel(
        previewAvailableVersion: AppDelegate.previewAvailableVersion
    )
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updateStatusModel,
        userDriverDelegate: nil
    )

    private var menuBarController: MenuBarController?
    private var monitorTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var monitoredProviders: Set<UsageProvider> = []
    private var monitoredRefreshInterval: UsageRefreshInterval?
    private var monitoredClaudeUsageMode: ClaudeUsageMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        menuBarController = MenuBarController(
            model: model,
            preferences: preferences,
            updateStatusModel: updateStatusModel,
            onInstallUpdate: { [weak self] in
                self?.checkForUpdates()
            }
        )
        observePreferences()
        observeModel()
        if !updateStatusModel.isPreviewingUpdate {
            restartMonitor()
            startUpdateChecks()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
        updateCheckTask?.cancel()
        model.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLoginController.refresh()
        Task {
            await statusLineSettingsModel.refresh()
        }
    }

    func authorizeClaudeOAuthFromUserSelection()
        async -> ClaudeOAuthUserInitiatedAccessResult
    {
        await ClaudeOAuthUserInitiatedAuthorization()
            .requestAccessFromUserAction()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func startUpdateChecks() {
        guard !updateStatusModel.isPreviewingUpdate else { return }

        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                updateStatusModel.beginChecking()
                updaterController.updater.checkForUpdateInformation()

                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
            }
        }
    }

    private static var previewAvailableVersion: String? {
#if DEBUG
        ProcessInfo.processInfo.environment["AIUSAGE_PREVIEW_UPDATE_VERSION"]
#else
        nil
#endif
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
            _ = preferences.colorUsageRings
            _ = preferences.providerDisplayMode
            _ = preferences.refreshInterval
            _ = preferences.claudeUsageMode
            _ = preferences.appLanguage
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
