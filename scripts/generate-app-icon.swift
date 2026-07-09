#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift <output.icns>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("CodexUsageBar-\(UUID().uuidString).iconset")

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer {
    try? fileManager.removeItem(at: iconsetURL)
}

let icons = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for (points, scale) in icons {
    let pixels = points * scale
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let filename = "icon_\(points)x\(points)\(suffix).png"
    let data = pngIcon(size: pixels)
    try data.write(to: iconsetURL.appendingPathComponent(filename))
}

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr)
    exit(process.terminationStatus)
}

private func pngIcon(size: Int) -> Data {
    let canvas = NSSize(width: size, height: size)
    let scale = CGFloat(size) / 1024.0
    let image = NSImage(size: canvas)

    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let tile = NSRect(x: 78 * scale, y: 78 * scale, width: 868 * scale, height: 868 * scale)
    let radius = 218 * scale
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    drawShadowedBase(tilePath)

    NSGraphicsContext.saveGraphicsState()
    tilePath.setClip()

    NSGradient(colors: [
        NSColor(calibratedWhite: 0.22, alpha: 1.0),
        NSColor(calibratedWhite: 0.10, alpha: 1.0),
        NSColor(calibratedWhite: 0.035, alpha: 1.0)
    ])?.draw(in: tile, angle: -90)

    drawUsageRing(scale: scale)

    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
    tilePath.lineWidth = max(1, 2.2 * scale)
    tilePath.stroke()

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render icon")
    }
    return data
}

private func drawShadowedBase(_ path: NSBezierPath) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.set()
    NSColor.black.withAlphaComponent(0.20).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// One unified badge: a thick circular usage ring (progress + dim track) with a
/// single solid terminal chevron centered inside it. Drawn together into one
/// transparency layer so the whole motif casts exactly one soft contact shadow.
private func drawUsageRing(scale: CGFloat) {
    guard let cgContext = NSGraphicsContext.current?.cgContext else { return }

    let center = CGPoint(x: 512 * scale, y: 512 * scale)
    let outerRadius = 304 * scale
    let ringWidth = 112 * scale
    let ringRadius = outerRadius - ringWidth / 2

    let startAngle: CGFloat = .pi / 2
    let sweepFraction: CGFloat = 0.73
    let sweepAngle = sweepFraction * 2 * .pi
    let endAngle = startAngle - sweepAngle

    cgContext.saveGState()
    cgContext.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: 22 * scale,
        color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    cgContext.beginTransparencyLayer(auxiliaryInfo: nil)

    // Dim track: the un-used remainder of the ring.
    cgContext.saveGState()
    let trackPath = CGMutablePath()
    trackPath.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    cgContext.addPath(trackPath)
    cgContext.setLineWidth(ringWidth)
    cgContext.setLineCap(.round)
    cgContext.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.14).cgColor)
    cgContext.strokePath()
    cgContext.restoreGState()

    // Bright accent progress arc (~73% swept) — the dominant usage/metering read.
    cgContext.saveGState()
    let progressPath = CGMutablePath()
    progressPath.addArc(center: center, radius: ringRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    cgContext.addPath(progressPath)
    cgContext.setLineWidth(ringWidth)
    cgContext.setLineCap(.round)
    cgContext.replacePathWithStrokedPath()
    cgContext.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        NSColor(calibratedRed: 0.42, green: 0.97, blue: 0.86, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.99, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.32, green: 0.40, blue: 0.98, alpha: 1.0).cgColor
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0.0, 0.55, 1.0]) {
        let gradientStart = CGPoint(x: center.x - outerRadius, y: center.y + outerRadius)
        let gradientEnd = CGPoint(x: center.x + outerRadius, y: center.y - outerRadius)
        cgContext.drawLinearGradient(gradient, start: gradientStart, end: gradientEnd, options: [])
    }
    cgContext.restoreGState()

    // Solid terminal chevron, centered inside the ring — ties the gauge to Codex/CLI.
    drawChevron(cgContext: cgContext, center: center, scale: scale)

    cgContext.endTransparencyLayer()
    cgContext.restoreGState()
}

private func drawChevron(cgContext: CGContext, center: CGPoint, scale: CGFloat) {
    let chevronHeight: CGFloat = 200 * scale
    let chevronReach: CGFloat = 108 * scale
    let strokeWidth: CGFloat = 60 * scale
    let xOffset: CGFloat = -18 * scale

    let topPoint = CGPoint(x: center.x + xOffset - chevronReach * 0.5, y: center.y + chevronHeight / 2)
    let midPoint = CGPoint(x: center.x + xOffset + chevronReach * 0.5, y: center.y)
    let bottomPoint = CGPoint(x: center.x + xOffset - chevronReach * 0.5, y: center.y - chevronHeight / 2)

    let chevronPath = CGMutablePath()
    chevronPath.move(to: topPoint)
    chevronPath.addLine(to: midPoint)
    chevronPath.addLine(to: bottomPoint)

    cgContext.saveGState()
    cgContext.addPath(chevronPath)
    cgContext.setLineWidth(strokeWidth)
    cgContext.setLineCap(.round)
    cgContext.setLineJoin(.round)
    cgContext.setStrokeColor(NSColor.white.cgColor)
    cgContext.strokePath()
    cgContext.restoreGState()
}
