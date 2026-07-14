import AppKit

/// Matches the app icon's motif: a usage-ring gauge with a terminal chevron nested
/// inside it, drawn as a template so AppKit tints it for the current menu bar appearance.
enum UsageMenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        // A drawing-handler representation is resolution independent. A bitmap
        // produced once with `lockFocus()` can otherwise be an 18-pixel source
        // stretched across a 36-pixel Retina menu-bar slot.
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cgContext = NSGraphicsContext.current?.cgContext else {
                return false
            }
            draw(in: cgContext)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Usage"
        return image
    }()

    private static func draw(in cgContext: CGContext) {
        let center = CGPoint(x: 9.0, y: 9.0)
        let outerRadius: CGFloat = 7.6
        let ringWidth: CGFloat = 2.8
        let ringRadius = outerRadius - ringWidth / 2

        let startAngle: CGFloat = .pi / 2
        let sweepFraction: CGFloat = 0.73
        let endAngle = startAngle - sweepFraction * 2 * .pi

        // Dim track — the un-used remainder of the ring.
        let track = CGMutablePath()
        track.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        cgContext.addPath(track)
        cgContext.setLineWidth(ringWidth)
        cgContext.setLineCap(.round)
        cgContext.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        cgContext.strokePath()

        // Bright progress arc (~73% swept), matching the app icon.
        let progress = CGMutablePath()
        progress.addArc(center: center, radius: ringRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        cgContext.addPath(progress)
        cgContext.setLineWidth(ringWidth)
        cgContext.setLineCap(.round)
        cgContext.setStrokeColor(NSColor.black.cgColor)
        cgContext.strokePath()

        // Terminal chevron, centered inside the ring.
        let chevronHeight: CGFloat = 3.6
        let chevronReach: CGFloat = 2.0
        let xOffset: CGFloat = -0.3
        let top = CGPoint(x: center.x + xOffset - chevronReach / 2, y: center.y + chevronHeight / 2)
        let mid = CGPoint(x: center.x + xOffset + chevronReach / 2, y: center.y)
        let bottom = CGPoint(x: center.x + xOffset - chevronReach / 2, y: center.y - chevronHeight / 2)

        let chevron = CGMutablePath()
        chevron.move(to: top)
        chevron.addLine(to: mid)
        chevron.addLine(to: bottom)
        cgContext.addPath(chevron)
        cgContext.setLineWidth(1.5)
        cgContext.setLineCap(.round)
        cgContext.setLineJoin(.round)
        cgContext.setStrokeColor(NSColor.black.cgColor)
        cgContext.strokePath()
    }
}
