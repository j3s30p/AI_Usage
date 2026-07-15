import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let preferences: AppPreferences
    private let updateStatusModel: UpdateStatusModel
    private let onInstallUpdate: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let alertOverlay: MenuBarAlertOverlayView
    private var freshnessTask: Task<Void, Never>?

    init(
        model: AppModel,
        preferences: AppPreferences,
        updateStatusModel: UpdateStatusModel,
        onInstallUpdate: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        self.updateStatusModel = updateStatusModel
        self.onInstallUpdate = onInstallUpdate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        alertOverlay = MenuBarAlertOverlayView(frame: .zero)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 340, height: 390)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                model: model,
                preferences: preferences,
                updateStatusModel: updateStatusModel,
                onInstallUpdate: onInstallUpdate
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            alertOverlay.frame = button.bounds
            button.addSubview(alertOverlay)

#if DEBUG
            if ProcessInfo.processInfo.environment["AIUSAGE_PREVIEW_UPDATE_VERSION"] != nil {
                Task { @MainActor [weak self, weak button] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, let button else { return }
                    showPopover(relativeTo: button)
                }
            }
#endif
        }

        updateStatusItem()
        freshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard let self else { return }
                updateStatusItem()
            }
        }
    }

    deinit {
        freshnessTask?.cancel()
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let providers = UsageProvider.allCases.filter {
            preferences.enabledProviders.contains($0)
        }

        if providers.isEmpty {
            let image = NSImage(
                systemSymbolName: "chart.pie",
                accessibilityDescription: "AiUsage"
            )
            image?.isTemplate = true
            statusItem.length = 28
            button.image = image
            alertOverlay.clear()
            button.setAccessibilityLabel("AiUsage")
            button.toolTip = "AiUsage"
            return
        }

        let now = Date.now
        let segments = providers.map { provider in
            let snapshot = menuBarSnapshot(for: provider, at: now)
            let window = snapshot?.menuBarWindow
            return MenuBarStatusSegment(
                name: provider.displayName,
                logoAssetName: preferences.providerDisplayMode == .logo
                    ? provider.logoAssetName
                    : nil,
                logoSourceInsetFraction: provider.logoSourceInsetFraction,
                remainingFraction: window?.remainingFraction,
                percentageText: preferences.showPercentage
                    ? window.map { "\($0.remainingPercentage)%" }
                    : nil
            )
        }
        let rendering = MenuBarStatusImageRenderer.makeRendering(
            segments: segments,
            usesUsageRingColors: preferences.colorUsageRings
        )
        statusItem.length = rendering.image.size.width + 10
        button.image = rendering.image
        alertOverlay.frame = button.bounds
        alertOverlay.update(with: rendering)

        let accessibilityLabel = providers.map { provider in
            let state = model.state(for: provider)
            if let snapshot = menuBarSnapshot(for: provider, at: now) {
                return String(
                    format: String(localized: "%@, %d%% remaining"),
                    provider.displayName,
                    snapshot.menuBarWindow.remainingPercentage
                )
            }
            if let failure = state.failure {
                return "\(provider.displayName), \(failure.message)"
            }
            if state.snapshot != nil {
                return String(
                    format: String(localized: "%@, last usage update delayed"),
                    provider.displayName
                )
            }
            return String(
                format: String(localized: "%@, loading usage"),
                provider.displayName
            )
        }.joined(separator: ", ")
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
    }

    private func menuBarSnapshot(
        for provider: UsageProvider,
        at date: Date
    ) -> UsageSnapshot? {
        guard let snapshot = model.state(for: provider).snapshot else { return nil }
        return snapshot.isCurrent(
            at: date,
            maximumAge: preferences.refreshInterval.maximumExpectedSnapshotAge
        ) ? snapshot : nil
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(relativeTo: sender)
        }
    }

    private func showPopover(relativeTo sender: NSStatusBarButton) {
        popover.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
    }
}
