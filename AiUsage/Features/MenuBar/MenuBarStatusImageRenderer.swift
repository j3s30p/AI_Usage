import AppKit

struct MenuBarStatusSegment: Equatable, Sendable {
    let name: String
    let logoAssetName: String?
    let logoSourceInsetFraction: CGFloat
    let remainingFraction: Double?
    let percentageText: String?

    init(
        name: String,
        logoAssetName: String? = nil,
        logoSourceInsetFraction: CGFloat = 0,
        remainingFraction: Double?,
        percentageText: String?
    ) {
        self.name = name
        self.logoAssetName = logoAssetName
        self.logoSourceInsetFraction = logoSourceInsetFraction
        self.remainingFraction = remainingFraction
        self.percentageText = percentageText
    }
}

struct MenuBarStatusRendering {
    let image: NSImage
    let zeroRemainingRingCenters: [NSPoint]
}

@MainActor
enum MenuBarStatusImageRenderer {
    private static let canvasHeight: CGFloat = 18
    private static let logoSize: CGFloat = 14
    private static let ringSize: CGFloat = 12
    private static let ringLineWidth: CGFloat = 1.4
    private static let itemSpacing: CGFloat = 4
    private static let dotSize: CGFloat = 2
    private static let providerSeparatorPadding: CGFloat = 8
    private static let providerSeparatorWidth: CGFloat = 1

    static func makeImage(segments: [MenuBarStatusSegment]) -> NSImage {
        makeRendering(segments: segments).image
    }

    static func makeRendering(segments: [MenuBarStatusSegment]) -> MenuBarStatusRendering {
        let font = NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let widths = segments.map { segmentWidth($0, attributes: attributes) }
        let contentWidth = widths.reduce(0, +)
            + providerSeparatorTotalWidth * CGFloat(max(segments.count - 1, 0))
        let imageSize = NSSize(width: ceil(contentWidth), height: canvasHeight)
        let ringCenters = ringCenterXPositions(segments, attributes: attributes)
        let zeroRemainingRingCenters = zip(segments, ringCenters).compactMap { pair -> NSPoint? in
            let (segment, x) = pair
            guard let remainingFraction = segment.remainingFraction,
                  RemainingRing.isDisplayedAsZero(remainingFraction)
            else { return nil }
            return NSPoint(x: x, y: canvasHeight / 2)
        }

        let image = NSImage(size: imageSize, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    x += providerSeparatorPadding
                    drawProviderSeparator(atX: x)
                    x += providerSeparatorWidth + providerSeparatorPadding
                }

                let markWidth = drawProviderMark(
                    segment,
                    atX: x,
                    attributes: attributes
                )
                x += markWidth + itemSpacing

                drawDot(atX: x)
                x += dotSize + itemSpacing

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
        return MenuBarStatusRendering(
            image: image,
            zeroRemainingRingCenters: zeroRemainingRingCenters
        )
    }

    private static func ringCenterXPositions(
        _ segments: [MenuBarStatusSegment],
        attributes: [NSAttributedString.Key: Any]
    ) -> [CGFloat] {
        var x: CGFloat = 0
        return segments.enumerated().map { index, segment in
            if index > 0 {
                x += providerSeparatorTotalWidth
            }
            x += providerMarkWidth(segment, attributes: attributes)
                + itemSpacing
                + dotSize
                + itemSpacing
            let centerX = x + ringSize / 2
            x += ringSize
            if let percentageText = segment.percentageText {
                x += itemSpacing + textSize(percentageText, attributes: attributes).width
            }
            return centerX
        }
    }

    private static func segmentWidth(
        _ segment: MenuBarStatusSegment,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        var width = providerMarkWidth(segment, attributes: attributes)
            + itemSpacing
            + dotSize
            + itemSpacing
            + ringSize
        if let percentageText = segment.percentageText {
            width += itemSpacing + textSize(percentageText, attributes: attributes).width
        }
        return width
    }

    private static var providerSeparatorTotalWidth: CGFloat {
        providerSeparatorPadding * 2 + providerSeparatorWidth
    }

    private static func providerMarkWidth(
        _ segment: MenuBarStatusSegment,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        if providerLogo(for: segment) != nil {
            return logoSize
        }
        return textSize(segment.name, attributes: attributes).width
    }

    @discardableResult
    private static func drawProviderMark(
        _ segment: MenuBarStatusSegment,
        atX x: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        if let logo = providerLogo(for: segment) {
            let rect = NSRect(
                x: x,
                y: (canvasHeight - logoSize) / 2,
                width: logoSize,
                height: logoSize
            )
            logo.draw(
                in: rect,
                from: providerLogoSourceRect(for: segment, image: logo),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return logoSize
        }

        let nameSize = textSize(segment.name, attributes: attributes)
        drawText(segment.name, atX: x, size: nameSize, attributes: attributes)
        return nameSize.width
    }

    private static func providerLogo(for segment: MenuBarStatusSegment) -> NSImage? {
        guard let logoAssetName = segment.logoAssetName else { return nil }
        return NSImage(named: NSImage.Name(logoAssetName))
    }

    private static func providerLogoSourceRect(
        for segment: MenuBarStatusSegment,
        image: NSImage
    ) -> NSRect {
        let inset = min(max(segment.logoSourceInsetFraction, 0), 0.49)
        guard inset > 0 else { return .zero }

        let xInset = image.size.width * inset
        let yInset = image.size.height * inset
        return NSRect(
            x: xInset,
            y: yInset,
            width: image.size.width - (xInset * 2),
            height: image.size.height - (yInset * 2)
        )
    }

    private static func drawDot(atX x: CGFloat) {
        let rect = NSRect(
            x: x,
            y: (canvasHeight - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        NSColor.white.withAlphaComponent(0.68).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static func drawProviderSeparator(atX x: CGFloat) {
        let separatorHeight: CGFloat = 10
        let rect = NSRect(
            x: x,
            y: (canvasHeight - separatorHeight) / 2,
            width: providerSeparatorWidth,
            height: separatorHeight
        )
        NSColor.white.withAlphaComponent(0.38).setFill()
        NSBezierPath(rect: rect).fill()
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
        guard !RemainingRing.isDisplayedAsZero(remaining) else { return }

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
