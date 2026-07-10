import AppKit
import CodexUsageCore
import CodexUsageUI
import SwiftUI

private struct RenderCase {
    let name: String
    let timeframe: UsageTimeframe
    let buckets: [DailyUsageBucket]
    let colorScheme: ColorScheme
    let selectedIndex: Int?

    init(
        name: String,
        timeframe: UsageTimeframe,
        buckets: [DailyUsageBucket],
        colorScheme: ColorScheme,
        selectedIndex: Int? = nil
    ) {
        self.name = name
        self.timeframe = timeframe
        self.buckets = buckets
        self.colorScheme = colorScheme
        self.selectedIndex = selectedIndex
    }
}

@main
@MainActor
enum CodexUsageVisualChecks {
    private static let outputSize = NSSize(width: 300, height: 186)

    static func main() throws {
        _ = NSApplication.shared
        let outputDirectory = try resolvedOutputDirectory()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var renderedData: [String: Data] = [:]
        for renderCase in renderCases {
            let data = try render(renderCase)
            guard data.count > 2_000 else {
                throw VisualCheckFailure("\(renderCase.name) produced an unexpectedly small image")
            }
            let destination = outputDirectory.appendingPathComponent("\(renderCase.name).png")
            try data.write(to: destination, options: .atomic)
            renderedData[renderCase.name] = data
            print("PASS render \(renderCase.name) bytes=\(data.count) path=\(destination.path)")
        }

        guard renderedData["month-light"] != renderedData["month-dark"] else {
            throw VisualCheckFailure("Light and dark chart renders should differ")
        }
        print("PASS lightAndDarkRendersDiffer")
    }

    private static func render(_ renderCase: RenderCase) throws -> Data {
        let maxTokens = renderCase.buckets.map(\.tokens).max() ?? 0
        let isDark = renderCase.colorScheme == .dark
        let backgroundColor = isDark
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor.white
        let rootView = ZStack {
            Color(nsColor: backgroundColor)
            UsageLineChart(
                buckets: renderCase.buckets,
                maxTokens: maxTokens,
                timeframe: renderCase.timeframe,
                selectedIndex: renderCase.selectedIndex
            )
            .frame(width: 264, height: 150)
            .padding(18)
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .preferredColorScheme(renderCase.colorScheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: outputSize)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hostingView.appearance = appearance
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = backgroundColor.cgColor
        let containerView = NSView(frame: hostingView.frame)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = backgroundColor.cgColor
        containerView.addSubview(hostingView)
        hostingView.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.backgroundColor = backgroundColor
        window.contentView = containerView
        hostingView.frame = containerView.bounds
        containerView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = containerView.bitmapImageRepForCachingDisplay(in: containerView.bounds) else {
            throw VisualCheckFailure("Could not allocate a bitmap for \(renderCase.name)")
        }
        containerView.cacheDisplay(in: containerView.bounds, to: representation)
        try validatePixels(
            representation,
            renderCase: renderCase
        )
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VisualCheckFailure("Could not encode \(renderCase.name) as PNG")
        }
        return data
    }

    private static func validatePixels(
        _ representation: NSBitmapImageRep,
        renderCase: RenderCase
    ) throws {
        guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else {
            throw VisualCheckFailure("\(renderCase.name) produced an empty bitmap")
        }

        let scaleX = CGFloat(representation.pixelsWide) / outputSize.width
        let scaleY = CGFloat(representation.pixelsHigh) / outputSize.height
        func color(at point: CGPoint) -> NSColor? {
            let x = min(max(Int((point.x * scaleX).rounded()), 0), representation.pixelsWide - 1)
            let topY = min(max(Int((point.y * scaleY).rounded()), 0), representation.pixelsHigh - 1)
            return representation.colorAt(x: x, y: topY)?.usingColorSpace(.deviceRGB)
        }

        guard let background = color(at: CGPoint(x: 2, y: 2)) else {
            throw VisualCheckFailure("\(renderCase.name) has no readable background pixel")
        }
        let brightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
        if renderCase.colorScheme == .light, brightness < 0.75 {
            throw VisualCheckFailure("\(renderCase.name) rendered a dark background in light mode")
        }
        if renderCase.colorScheme == .dark, brightness > 0.45 {
            throw VisualCheckFailure("\(renderCase.name) rendered a light background in dark mode")
        }

        for point in [
            CGPoint(x: outputSize.width / 2, y: 2),
            CGPoint(x: outputSize.width - 2, y: 2),
            CGPoint(x: 2, y: outputSize.height / 2),
            CGPoint(x: outputSize.width - 2, y: outputSize.height / 2),
            CGPoint(x: 2, y: outputSize.height - 2),
            CGPoint(x: outputSize.width / 2, y: outputSize.height - 2),
            CGPoint(x: outputSize.width - 2, y: outputSize.height - 2)
        ] {
            guard let actual = color(at: point), colorDistance(actual, background) < 0.08 else {
                let actualDescription = color(at: point).map(describeColor) ?? "unavailable"
                throw VisualCheckFailure(
                    "\(renderCase.name) has an unexpected background region at \(point): "
                        + "actual=\(actualDescription) expected=\(describeColor(background))"
                )
            }
        }

        var titleInkPixels = 0
        for x in stride(from: CGFloat(18), through: 56, by: 1) {
            for y in stride(from: CGFloat(18), through: 29, by: 1) {
                if let actual = color(at: CGPoint(x: x, y: y)),
                   colorDistance(actual, background) > 0.10 {
                    titleInkPixels += 1
                }
            }
        }
        guard titleInkPixels >= 12 else {
            throw VisualCheckFailure("\(renderCase.name) did not render the Tokens axis title")
        }

    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent)
            + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent)
            + abs(lhs.alphaComponent - rhs.alphaComponent)
    }

    private static func describeColor(_ color: NSColor) -> String {
        String(
            format: "%.3f,%.3f,%.3f,%.3f",
            color.redComponent,
            color.greenComponent,
            color.blueComponent,
            color.alphaComponent
        )
    }

    private static func resolvedOutputDirectory() throws -> URL {
        if let outputIndex = CommandLine.arguments.firstIndex(of: "--output") {
            let valueIndex = CommandLine.arguments.index(after: outputIndex)
            guard CommandLine.arguments.indices.contains(valueIndex) else {
                throw VisualCheckFailure("--output requires a directory")
            }
            return URL(fileURLWithPath: CommandLine.arguments[valueIndex], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/chart-snapshots", isDirectory: true)
    }

    private static var renderCases: [RenderCase] {
        let monthBuckets = dailyBuckets(count: 30) { day in
            let wave = Int64((day * day * 83_117) % 4_200_000)
            return day.isMultiple(of: 8) ? 0 : wave + 350_000
        }
        return [
            RenderCase(name: "week-dark", timeframe: .seven, buckets: Array(monthBuckets.suffix(7)), colorScheme: .dark),
            RenderCase(name: "month-light", timeframe: .thirty, buckets: monthBuckets, colorScheme: .light),
            RenderCase(name: "month-dark", timeframe: .thirty, buckets: monthBuckets, colorScheme: .dark),
            RenderCase(name: "tooltip-leading-light", timeframe: .thirty, buckets: monthBuckets, colorScheme: .light, selectedIndex: 0),
            RenderCase(name: "tooltip-trailing-dark", timeframe: .thirty, buckets: monthBuckets, colorScheme: .dark, selectedIndex: monthBuckets.count - 1),
            RenderCase(name: "quarter-light", timeframe: .ninety, buckets: dailyBuckets(count: 90) { Int64(($0 * 791_993) % 8_000_000) }, colorScheme: .light),
            RenderCase(
                name: "all-sparse-dark",
                timeframe: .all,
                buckets: [
                    DailyUsageBucket(startDate: "2024-01-01", tokens: 120_000),
                    DailyUsageBucket(startDate: "2024-01-15", tokens: 4_200_000),
                    DailyUsageBucket(startDate: "2025-06-01", tokens: 900_000),
                    DailyUsageBucket(startDate: "2026-07-09", tokens: 7_800_000)
                ],
                colorScheme: .dark
            ),
            RenderCase(name: "zero-light", timeframe: .seven, buckets: dailyBuckets(count: 7) { _ in 0 }, colorScheme: .light),
            RenderCase(
                name: "one-point-dark",
                timeframe: .all,
                buckets: [DailyUsageBucket(startDate: "2026-07-09", tokens: Int64.max)],
                colorScheme: .dark,
                selectedIndex: 0
            ),
            RenderCase(
                name: "two-point-light",
                timeframe: .all,
                buckets: [
                    DailyUsageBucket(startDate: "2026-07-01", tokens: 1),
                    DailyUsageBucket(startDate: "2026-07-09", tokens: 9_999_999_999)
                ],
                colorScheme: .light
            )
        ]
    }

    private static func dailyBuckets(
        count: Int,
        tokens: (Int) -> Int64
    ) -> [DailyUsageBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 4, day: 11)) ?? Date()
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            return DailyUsageBucket(
                startDate: UsageWindows.bucketStartString(for: date, timeZone: calendar.timeZone),
                tokens: tokens(offset)
            )
        }
    }
}

private struct VisualCheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
