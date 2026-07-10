import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let preferences: AppPreferences
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(model: AppModel, preferences: AppPreferences) {
        self.model = model
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 240)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(model: model, preferences: preferences)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }

        updateStatusItem()
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
            button.setAccessibilityLabel("AiUsage")
            button.toolTip = "AiUsage"
            return
        }

        let segments = providers.map { provider in
            let snapshot = model.state(for: provider).snapshot
            return MenuBarStatusSegment(
                name: provider.displayName,
                remainingFraction: snapshot?.remainingFraction,
                percentageText: preferences.showPercentage
                    ? snapshot.map { "\($0.remainingPercentage)%" } ?? "–%"
                    : nil
            )
        }
        let image = MenuBarStatusImageRenderer.makeImage(segments: segments)
        statusItem.length = image.size.width + 10
        button.image = image

        let accessibilityLabel = providers.map { provider in
            if let snapshot = model.state(for: provider).snapshot {
                return "\(provider.displayName), \(snapshot.remainingPercentage)% 남음"
            }
            if let failure = model.state(for: provider).failure {
                return "\(provider.displayName), \(failure.message)"
            }
            return "\(provider.displayName), 사용량을 불러오는 중"
        }.joined(separator: ", ")
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
