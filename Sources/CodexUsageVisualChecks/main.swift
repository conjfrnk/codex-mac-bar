import AppKit
import CodexUsageCore
import CodexUsageUI
import Darwin
import SwiftUI

private struct RenderCase {
    let name: String
    let timeframe: UsageTimeframe
    let buckets: [DailyUsageBucket]
    let colorScheme: ColorScheme
    let selectedIndex: Int?
    let positions: [Double]?

    init(
        name: String,
        timeframe: UsageTimeframe,
        buckets: [DailyUsageBucket],
        colorScheme: ColorScheme,
        selectedIndex: Int? = nil,
        positions: [Double]? = nil
    ) {
        self.name = name
        self.timeframe = timeframe
        self.buckets = buckets
        self.colorScheme = colorScheme
        self.selectedIndex = selectedIndex
        self.positions = positions
    }
}

@main
@MainActor
enum CodexUsageVisualChecks {
    private static let outputSize = NSSize(width: 300, height: 186)
    private static let fixtureLocale = Locale(identifier: "en_US_POSIX")

    private static var fixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = fixtureLocale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func main() {
        do {
            try run()
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit((error as? VisualCheckFailure)?.exitCode ?? 1)
        }
    }

    private static func run() throws {
        let outputDirectory = try resolvedOutputDirectory()
        _ = NSApplication.shared
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

        guard renderedData["tooltip-leading-light"] != renderedData["month-light"],
              renderedData["tooltip-trailing-dark"] != renderedData["month-dark"]
        else {
            throw VisualCheckFailure("Pinned selections should visibly render their marker and tooltip")
        }
        print("PASS pinnedSelectionsRender")

        try validatePinnedTooltipRegion(
            selected: renderedData["tooltip-leading-light"],
            base: renderedData["month-light"],
            name: "tooltip-leading-light"
        )
        try validatePinnedTooltipRegion(
            selected: renderedData["tooltip-trailing-dark"],
            base: renderedData["month-dark"],
            name: "tooltip-trailing-dark"
        )
        try validateEmptyOrZeroState(renderedData["zero-light"], name: "zero-light")
        try validateEmptyOrZeroState(renderedData["empty-light"], name: "empty-light")
        try validateSparseBaseline(renderedData["all-sparse-dark"])
        print("PASS stateSpecificPixelLandmarks")
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
                selectedIndex: renderCase.selectedIndex,
                positions: renderCase.positions,
                calendar: fixtureCalendar,
                locale: fixtureLocale
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

        if renderCase.buckets.contains(where: { $0.tokens > 0 }) {
            var accentPixels = 0
            var strongestContrast: CGFloat = 0
            // The chart is padded by 18 points and its plot occupies the region
            // below the title and above the date labels. Text/grid pixels are
            // effectively achromatic, so a chromatic scan detects the actual
            // usage stroke/marker rather than merely proving that some ink exists.
            for x in stride(from: CGFloat(58), through: 280, by: 1) {
                for y in stride(from: CGFloat(34), through: 143, by: 1) {
                    guard let actual = color(at: CGPoint(x: x, y: y)) else { continue }
                    let components = [actual.redComponent, actual.greenComponent, actual.blueComponent]
                    guard let minimum = components.min(), let maximum = components.max(),
                          maximum - minimum > 0.10,
                          colorDistance(actual, background) > 0.16
                    else { continue }
                    accentPixels += 1
                    strongestContrast = max(strongestContrast, contrastRatio(actual, background))
                }
            }
            guard accentPixels >= 18 else {
                throw VisualCheckFailure("\(renderCase.name) did not render a detectable usage line or marker")
            }
            guard strongestContrast >= 3 else {
                throw VisualCheckFailure(
                    "\(renderCase.name) chart accent contrast was only \(String(format: "%.2f", strongestContrast)):1"
                )
            }
        }
    }

    private static func validatePinnedTooltipRegion(
        selected: Data?,
        base: Data?,
        name: String
    ) throws {
        guard let selected,
              let base,
              let selectedImage = NSBitmapImageRep(data: selected),
              let baseImage = NSBitmapImageRep(data: base),
              selectedImage.pixelsWide == baseImage.pixelsWide,
              selectedImage.pixelsHigh == baseImage.pixelsHigh
        else { throw VisualCheckFailure("Could not compare tooltip pixels for \(name)") }

        let region = CGRect(x: 55, y: 45, width: 225, height: 100)
        let changed = pointNormalizedPixelCount(in: selectedImage, region: region) { x, y in
            guard let lhs = selectedImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let rhs = baseImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else { return false }
            return colorDistance(lhs, rhs) > 0.08
        }
        guard changed >= 1_000 else {
            throw VisualCheckFailure(
                "\(name) changed only \(Int(changed)) tooltip-region pixels; marker-only output is insufficient"
            )
        }
    }

    private static func validateEmptyOrZeroState(_ data: Data?, name: String) throws {
        guard let data, let image = NSBitmapImageRep(data: data),
              let background = image.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)
        else { throw VisualCheckFailure("Could not inspect the \(name) render") }
        let messageRegion = CGRect(x: 90, y: 60, width: 140, height: 65)
        let ink = pointNormalizedPixelCount(in: image, region: messageRegion) { x, y in
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            return colorDistance(color, background) > 0.25
        }
        guard ink >= 100 else {
            throw VisualCheckFailure("\(name) did not render its central state message")
        }
    }

    private static func validateSparseBaseline(_ data: Data?) throws {
        guard let data, let image = NSBitmapImageRep(data: data),
              let background = image.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)
        else { throw VisualCheckFailure("Could not inspect the sparse all-time render") }
        let baselineRegion = CGRect(x: 55, y: 132, width: 225, height: 16)
        var horizontalBins = Set<Int>()
        let accent = pointNormalizedPixelCount(in: image, region: baselineRegion) { x, y in
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard let minimum = components.min(), let maximum = components.max(),
                  maximum - minimum > 0.10,
                  colorDistance(color, background) > 0.16
            else { return false }
            let pointX = CGFloat(x) * outputSize.width / CGFloat(image.pixelsWide)
            horizontalBins.insert(Int(pointX / 10))
            return true
        }
        guard accent >= 100, horizontalBins.count >= 10 else {
            throw VisualCheckFailure(
                "Sparse all-time line did not visibly return to zero across its calendar gaps"
            )
        }
    }

    private static func pointNormalizedPixelCount(
        in image: NSBitmapImageRep,
        region: CGRect,
        predicate: (Int, Int) -> Bool
    ) -> CGFloat {
        let scaleX = CGFloat(image.pixelsWide) / outputSize.width
        let scaleY = CGFloat(image.pixelsHigh) / outputSize.height
        let minimumX = max(0, Int((region.minX * scaleX).rounded(.down)))
        let maximumX = min(image.pixelsWide - 1, Int((region.maxX * scaleX).rounded(.up)))
        let minimumY = max(0, Int((region.minY * scaleY).rounded(.down)))
        let maximumY = min(image.pixelsHigh - 1, Int((region.maxY * scaleY).rounded(.up)))
        var count = 0
        for y in minimumY...maximumY {
            for x in minimumX...maximumX where predicate(x, y) {
                count += 1
            }
        }
        return CGFloat(count) / max(scaleX * scaleY, 1)
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

    private static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * linearize(color.redComponent))
            + (0.7152 * linearize(color.greenComponent))
            + (0.0722 * linearize(color.blueComponent))
    }

    private static func resolvedOutputDirectory() throws -> URL {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/chart-snapshots", isDirectory: true)
        }
        guard arguments.count == 2,
              arguments[0] == "--output",
              !arguments[1].isEmpty,
              !arguments[1].hasPrefix("--")
        else {
            throw VisualCheckFailure(
                "usage: CodexUsageVisualChecks [--output <directory>]",
                exitCode: 64
            )
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static var renderCases: [RenderCase] {
        let monthBuckets = dailyBuckets(count: 30) { day in
            let wave = Int64((day * day * 83_117) % 4_200_000)
            return day.isMultiple(of: 8) ? 0 : wave + 350_000
        }
        let calendar = fixtureCalendar
        let allTimeNow = UsageWindows.date(
            from: "2026-07-13",
            timeZone: calendar.timeZone
        ) ?? Date(timeIntervalSince1970: 1_783_944_000)
        let sparseAllTimeBuckets = UsageRange(
            timeframe: .all,
            sourceBuckets: [
                DailyUsageBucket(startDate: "2024-01-01", tokens: 120_000),
                DailyUsageBucket(startDate: "2024-01-15", tokens: 4_200_000),
                DailyUsageBucket(startDate: "2025-06-01", tokens: 900_000),
                DailyUsageBucket(startDate: "2026-07-09", tokens: 7_800_000)
            ],
            now: allTimeNow,
            calendar: calendar
        ).chartBuckets
        let extremeRange = UsageRange(
            timeframe: .all,
            sourceBuckets: [
                DailyUsageBucket(startDate: "0001-01-01", tokens: 42),
                DailyUsageBucket(startDate: "0001-01-02", tokens: 20),
                DailyUsageBucket(startDate: "9999-12-31", tokens: 30)
            ],
            now: allTimeNow,
            calendar: calendar
        )
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
                buckets: sparseAllTimeBuckets,
                colorScheme: .dark
            ),
            RenderCase(name: "zero-light", timeframe: .seven, buckets: dailyBuckets(count: 7) { _ in 0 }, colorScheme: .light),
            RenderCase(name: "empty-light", timeframe: .seven, buckets: [], colorScheme: .light),
            RenderCase(
                name: "one-point-dark",
                timeframe: .all,
                buckets: [DailyUsageBucket(startDate: "2026-07-09", tokens: Int64.max)],
                colorScheme: .dark,
                selectedIndex: 0,
                positions: [1]
            ),
            RenderCase(
                name: "two-point-light",
                timeframe: .all,
                buckets: [
                    DailyUsageBucket(startDate: "2026-07-01", tokens: 1),
                    DailyUsageBucket(startDate: "2026-07-09", tokens: 9_999_999_999)
                ],
                colorScheme: .light
            ),
            RenderCase(
                name: "extreme-span-light",
                timeframe: .all,
                buckets: extremeRange.chartBuckets,
                colorScheme: .light,
                positions: extremeRange.chartPositions
            )
        ]
    }

    private static func dailyBuckets(
        count: Int,
        tokens: (Int) -> Int64
    ) -> [DailyUsageBucket] {
        let calendar = fixtureCalendar
        guard let start = calendar.date(from: DateComponents(year: 2026, month: 4, day: 11)) else {
            return []
        }
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
    let exitCode: Int32

    init(_ description: String, exitCode: Int32 = 1) {
        self.description = description
        self.exitCode = exitCode
    }
}
