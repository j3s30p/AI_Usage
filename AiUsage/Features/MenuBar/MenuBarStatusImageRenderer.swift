import AppKit

struct MenuBarStatusSegment: Equatable, Sendable {
    let name: String
    let remainingFraction: Double?
    let percentageText: String?
}

@MainActor
enum MenuBarStatusImageRenderer {
    private static let canvasHeight: CGFloat = 18
    private static let ringSize: CGFloat = 12
    private static let ringLineWidth: CGFloat = 1.4
    private static let itemSpacing: CGFloat = 4
    private static let providerSpacing: CGFloat = 10

    static func makeImage(segments: [MenuBarStatusSegment]) -> NSImage {
        let font = NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let widths = segments.map { segmentWidth($0, attributes: attributes) }
        let contentWidth = widths.reduce(0, +)
            + providerSpacing * CGFloat(max(segments.count - 1, 0))
        let imageSize = NSSize(width: ceil(contentWidth), height: canvasHeight)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                if index > 0 { x += providerSpacing }

                let nameSize = textSize(segment.name, attributes: attributes)
                drawText(segment.name, atX: x, size: nameSize, attributes: attributes)
                x += nameSize.width + itemSpacing

                let ringRect = NSRect(
                    x: x,
                    y: (canvasHeight - ringSize) / 2,
                    width: ringSize,
                    height: ringSize
                )
                drawRing(in: ringRect, remainingFraction: segment.remainingFraction)
                x += ringSize

                if let percentageText = segment.percentageText {
                    x += itemSpacing
                    let percentageSize = textSize(percentageText, attributes: attributes)
                    drawText(
                        percentageText,
                        atX: x,
                        size: percentageSize,
                        attributes: attributes
                    )
                    x += percentageSize.width
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func segmentWidth(
        _ segment: MenuBarStatusSegment,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        var width = textSize(segment.name, attributes: attributes).width
            + itemSpacing
            + ringSize
        if let percentageText = segment.percentageText {
            width += itemSpacing + textSize(percentageText, attributes: attributes).width
        }
        return width
    }

    private static func textSize(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSSize {
        (text as NSString).size(withAttributes: attributes)
    }

    private static func drawText(
        _ text: String,
        atX x: CGFloat,
        size: NSSize,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let y = floor((canvasHeight - size.height) / 2) + 1
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    private static func drawRing(in rect: NSRect, remainingFraction: Double?) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - ringLineWidth) / 2

        guard let remainingFraction else {
            let unknown = fullCircle(center: center, radius: radius)
            unknown.lineWidth = ringLineWidth
            unknown.lineCapStyle = .round
            var dash: [CGFloat] = [1.2, 2]
            unknown.setLineDash(&dash, count: dash.count, phase: 0)
            NSColor.white.withAlphaComponent(0.72).setStroke()
            unknown.stroke()
            return
        }

        let remaining = RemainingRing.normalizedRemaining(remainingFraction)
        guard remaining > 0 else { return }

        let foreground: NSBezierPath
        if remaining >= 1 {
            foreground = fullCircle(center: center, radius: radius)
        } else {
            foreground = NSBezierPath()
            let startAngle = 90 - (360 * (1 - remaining))
            foreground.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: -270,
                clockwise: true
            )
        }
        foreground.lineWidth = ringLineWidth
        foreground.lineCapStyle = .round
        NSColor.white.setStroke()
        foreground.stroke()
    }

    private static func fullCircle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360
        )
        return path
    }
}
