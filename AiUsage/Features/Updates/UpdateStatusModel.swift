import Observation
import Sparkle

@Observable
@MainActor
final class UpdateStatusModel: NSObject, SPUUpdaterDelegate {
    let currentVersion: String
    private(set) var latestVersion: String?
    private(set) var availableVersion: String?
    private(set) var isChecking: Bool

    private let previewAvailableVersion: String?

    init(
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—",
        previewAvailableVersion: String? = nil
    ) {
        self.currentVersion = currentVersion
        self.previewAvailableVersion = previewAvailableVersion
        latestVersion = previewAvailableVersion
        availableVersion = previewAvailableVersion
        isChecking = previewAvailableVersion == nil
        super.init()
    }

    var isPreviewingUpdate: Bool {
        previewAvailableVersion != nil
    }

    func beginChecking() {
        guard !isPreviewingUpdate else { return }
        isChecking = true
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        Task { @MainActor in
            latestVersion = item.displayVersionString
            availableVersion = item.displayVersionString
            isChecking = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: any Error
    ) {
        Task { @MainActor in
            latestVersion = currentVersion
            availableVersion = nil
            isChecking = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: any Error
    ) {
        Task { @MainActor in
            isChecking = false
        }
    }
}
