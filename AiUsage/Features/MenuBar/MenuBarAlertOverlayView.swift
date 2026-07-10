import AppKit

@MainActor
final class MenuBarAlertOverlayView: NSView {
    private static let ringSize: CGFloat = 12
    private static let ringLineWidth: CGFloat = 1.4
    private static let remainingArcDegrees: CGFloat = 1

    private var renderedImageSize = NSSize.zero
    private var zeroRemainingRingCenters: [NSPoint] = []

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
        zeroRemainingRingCenters = rendering.zeroRemainingRingCenters
        needsDisplay = true
    }

    func clear() {
        renderedImageSize = .zero
        zeroRemainingRingCenters = []
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !zeroRemainingRingCenters.isEmpty else { return }
        let imageOrigin = NSPoint(
            x: floor((bounds.width - renderedImageSize.width) / 2),
            y: floor((bounds.height - renderedImageSize.height) / 2)
        )
        let radius = (Self.ringSize - Self.ringLineWidth) / 2

        NSColor.systemRed.setStroke()
        for relativeCenter in zeroRemainingRingCenters {
            let center = NSPoint(
                x: imageOrigin.x + relativeCenter.x,
                y: imageOrigin.y + relativeCenter.y
            )
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90 - Self.remainingArcDegrees / 2,
                endAngle: 90 + Self.remainingArcDegrees / 2
            )
            path.lineWidth = Self.ringLineWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
