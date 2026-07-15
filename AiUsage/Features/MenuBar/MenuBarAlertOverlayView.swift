import AppKit

@MainActor
final class MenuBarAlertOverlayView: NSView {
    private static let ringSize: CGFloat = 12
    private static let ringLineWidth: CGFloat = 1.4

    private var renderedImageSize = NSSize.zero
    private var ringOverlays: [MenuBarRingOverlay] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with rendering: MenuBarStatusRendering) {
        renderedImageSize = rendering.image.size
        ringOverlays = rendering.ringOverlays
        needsDisplay = true
    }

    func clear() {
        renderedImageSize = .zero
        ringOverlays = []
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !ringOverlays.isEmpty else { return }
        let imageOrigin = NSPoint(
            x: floor((bounds.width - renderedImageSize.width) / 2),
            y: floor((bounds.height - renderedImageSize.height) / 2)
        )
        let radius = (Self.ringSize - Self.ringLineWidth) / 2

        for overlay in ringOverlays {
            let center = NSPoint(
                x: imageOrigin.x + overlay.center.x,
                y: imageOrigin.y + overlay.center.y
            )
            let remaining = RemainingRing.normalizedRemaining(
                overlay.remainingFraction
            )
            let path = NSBezierPath()
            if RemainingRing.isDisplayedAsZero(remaining) {
                path.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 89.5,
                    endAngle: 90.5
                )
            } else if remaining >= 1 {
                path.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 0,
                    endAngle: 360
                )
            } else {
                path.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90 - (360 * (1 - remaining)),
                    endAngle: -270,
                    clockwise: true
                )
            }
            path.lineWidth = Self.ringLineWidth
            path.lineCapStyle = .round
            overlay.color.appKitColor.setStroke()
            path.stroke()
        }
    }
}

private extension UsageRingColor {
    var appKitColor: NSColor {
        switch self {
        case .critical: .systemRed
        case .warning: .systemYellow
        case .healthy: .systemGreen
        }
    }
}
