import CodexUsageCore
import Foundation
import SwiftUI

public struct UsageLineChart: View {
    private let buckets: [DailyUsageBucket]
    private let maxTokens: Int64
    private let timeframe: UsageTimeframe
    private let positions: [Double]
    private let axisPolicy: UsageChartAxisPolicy
    private let calendar: Calendar
    private let axisDateFormatter: DateFormatter
    private let tooltipDateFormatter: DateFormatter
    private let locale: Locale
    private let selectedIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredIndex: Int?
    @State private var pinnedIndex: Int?
    @State private var isHovering = false
    @State private var suppressHoverUntilReentry = false
    @FocusState private var isFocused: Bool

    private var activeIndex: Int? {
        hoveredIndex ?? pinnedIndex
    }

    private var hasActivity: Bool {
        maxTokens > 0 && buckets.contains { $0.tokens > 0 }
    }

    /// The peak token count rounded up to a "nice" round number (see
    /// `UsageChartMath.niceAxisMaximum`), used both for the Y-axis gridlines and to
    /// scale the plotted line, so the axis reads as normal numbers (e.g. "5B") rather
    /// than the raw peak's exact, oddly-precise value (e.g. "4.181B").
    private var yAxisMax: Int64 {
        UsageChartMath.niceAxisMaximum(maxTokens)
    }

    private var yAxisValues: [Int64] {
        guard yAxisMax > 0 else { return [0] }
        return [yAxisMax, yAxisMax / 2, 0].reduce(into: [Int64]()) { values, value in
            if !values.contains(value) {
                values.append(value)
            }
        }
    }

    private var tickLabelWidth: CGFloat {
        axisPolicy.dateLabelStyle == .singleLetterWeekday ? 18 : 56
    }

    /// Approximate rendered glyph width, distinct from the deliberately wider
    /// alignment frame. Collision filtering the transparent 56pt frame would
    /// unnecessarily remove ordinary month ticks whose text is only ~20pt wide.
    private var tickCollisionWidth: CGFloat {
        switch axisPolicy.dateLabelStyle {
        case .singleLetterWeekday: return 18
        case .abbreviatedWeekday: return 30
        case .numericMonthDay: return 32
        case .abbreviatedMonthDay: return 42
        case .abbreviatedMonthYear: return 56
        }
    }

    /// A darkened teal is used in light appearance because the system mint color
    /// is too close to white for a thin chart stroke. These fixed values retain
    /// greater than 3:1 contrast against the chart's light and dark backgrounds.
    private var accentColor: Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.42, green: 0.97, blue: 0.86)
        default:
            return Color(red: 0.00, green: 0.42, blue: 0.35)
        }
    }

    public init(
        buckets: [DailyUsageBucket],
        maxTokens: Int64,
        timeframe: UsageTimeframe,
        selectedIndex: Int? = nil,
        positions suppliedPositions: [Double]? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        let normalizedBuckets = buckets.map { bucket in
            DailyUsageBucket(startDate: bucket.startDate, tokens: max(bucket.tokens, 0))
        }
        let canonicalPositions = UsageChartMath.normalizedCalendarDayPositions(for: normalizedBuckets)
        let positions: [Double]
        if let suppliedPositions,
           Self.validPositions(suppliedPositions, count: normalizedBuckets.count) {
            positions = suppliedPositions
        } else {
            positions = canonicalPositions
        }
        let policy = UsageChartAxisPolicy.policy(
            for: timeframe,
            spanDays: UsageChartMath.calendarDaySpan(for: normalizedBuckets)
        )
        self.buckets = normalizedBuckets
        let observedMaximum = normalizedBuckets.map(\.tokens).max() ?? 0
        self.maxTokens = max(max(maxTokens, 0), observedMaximum)
        self.timeframe = timeframe
        self.positions = positions
        self.calendar = calendar
        self.locale = locale
        self.selectedIndex = selectedIndex.flatMap {
            normalizedBuckets.indices.contains($0) ? $0 : nil
        }
        axisPolicy = policy
        axisDateFormatter = Self.makeAxisDateFormatter(
            style: policy.dateLabelStyle,
            calendar: calendar,
            locale: locale
        )
        tooltipDateFormatter = Self.makeTooltipDateFormatter(
            calendar: calendar,
            locale: locale
        )
        // Treat the public selection as untrusted input. Keeping an out-of-range
        // value would be visually inert at first, but an arrow-key command could
        // then overflow (`Int.min - 1`) or carry an invalid index indefinitely.
        _pinnedIndex = State(
            initialValue: self.selectedIndex
        )
    }

    static func validPositions(_ positions: [Double], count: Int) -> Bool {
        guard positions.count == count,
              positions.allSatisfy(\.isFinite)
        else { return false }
        if count == 0 { return true }
        if count == 1 {
            return positions[0] >= 0 && positions[0] <= 1
        }
        guard let first = positions.first,
              let last = positions.last,
              abs(first) <= 1e-12,
              abs(last - 1) <= 1e-12
        else { return false }
        let minimumInterval = 1e-12
        return zip(positions, positions.dropFirst()).allSatisfy {
            let interval = $1 - $0
            return interval.isFinite && interval >= minimumInterval
        }
    }

    public var body: some View {
        if buckets.isEmpty {
            chartContent
        } else {
            chartContent
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        moveSelection(.right)
                    case .decrement:
                        moveSelection(.left)
                    @unknown default:
                        break
                    }
                }
        }
    }

    private var chartContent: some View {
        GeometryReader { proxy in
            let layout = ChartLayout(size: proxy.size)

            ZStack(alignment: .topLeading) {
                axes(in: layout)
                usageLine(in: layout)

                if buckets.isEmpty || !hasActivity {
                    Text("No activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .position(x: layout.plotRect.midX, y: layout.plotRect.midY)
                        .allowsHitTesting(false)
                } else if buckets.count == 1 {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                        .position(point(for: 0, in: layout))
                        .allowsHitTesting(false)
                }

                if let activeIndex, buckets.indices.contains(activeIndex) {
                    activeSelection(at: activeIndex, in: layout)
                }

                if !buckets.isEmpty {
                    interactionLayer(in: layout)
                }

                if let activeIndex, buckets.indices.contains(activeIndex) {
                    tooltip(at: activeIndex, in: layout)
                }
            }
        }
        .onChange(of: buckets) { newBuckets in
            synchronizeExternalSelection(
                to: selectedIndex.flatMap { newBuckets.indices.contains($0) ? $0 : nil }
            )
        }
        .onChange(of: timeframe) { _ in
            synchronizeExternalSelection(to: selectedIndex)
        }
        .onChange(of: selectedIndex) { newIndex in
            synchronizeExternalSelection(to: newIndex)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily token usage chart")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            buckets.isEmpty
                ? "There is no daily activity to inspect."
                : "Move the pointer, click, or use the left and right arrow keys to inspect daily values."
        )
    }

    @ViewBuilder
    private func axes(in layout: ChartLayout) -> some View {
        Text("Tokens")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: max(layout.plotRect.minX - 6, 1), alignment: .trailing)
            .position(x: max((layout.plotRect.minX - 6) / 2, 0), y: 6)

        ForEach(yAxisValues, id: \.self) { value in
            let y = yPosition(for: Double(value), in: layout)

            Path { path in
                path.move(to: CGPoint(x: layout.plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: layout.plotRect.maxX, y: y))
            }
            .stroke(Color.secondary.opacity(0.20), lineWidth: 1)

            Text(UsageChartAxisLabel.text(value))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: max(layout.plotRect.minX - 7, 1), alignment: .trailing)
                .position(x: max((layout.plotRect.minX - 7) / 2, 0), y: y)
        }

        Path { path in
            path.move(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.minY))
            path.addLine(to: CGPoint(x: layout.plotRect.minX, y: layout.plotRect.maxY))
            path.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.plotRect.maxY))
        }
        .stroke(Color.secondary.opacity(0.32), lineWidth: 1)

        let tickIndices = Self.nonoverlappingTickIndices(
            positions: positions,
            maximumTickCount: axisPolicy.maximumTickCount,
            plotWidth: layout.plotRect.width,
            labelWidth: tickCollisionWidth
        )
        ForEach(tickIndices, id: \.self) { index in
            let x = xPosition(for: index, in: layout)

            Path { path in
                path.move(to: CGPoint(x: x, y: layout.plotRect.maxY))
                path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY + 3))
            }
            .stroke(Color.secondary.opacity(0.40), lineWidth: 1)

            Text(axisDateLabel(at: index))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: tickLabelWidth, alignment: xAxisAlignment(for: index))
                .position(
                    x: xAxisLabelCenter(for: index, x: x, in: layout),
                    y: layout.plotRect.maxY + 13
                )
        }
    }

    @ViewBuilder
    private func usageLine(in layout: ChartLayout) -> some View {
        if hasActivity && buckets.count > 1 {
            let samples = UsageChartMath.renderSamples(
                values: buckets.map(\.tokens),
                positions: positions,
                maximumSampleCount: Self.renderSampleBudget(plotWidth: layout.plotRect.width)
            )
            Path { path in
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(
                        x: layout.plotRect.minX + (CGFloat(sample.position) * layout.plotRect.width),
                        y: yPosition(for: sample.value, in: layout)
                    )
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(
                accentColor,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    static func renderSampleBudget(plotWidth: CGFloat) -> Int {
        guard plotWidth.isFinite else { return 4_096 }
        let boundedWidth = min(max(plotWidth, 1), 1_024)
        return min(max(Int(boundedWidth.rounded(.up)) * 4, 16), 4_096)
    }

    /// Removes labels whose fixed-width frames would collide at highly clustered
    /// civil-date positions. The first and last dates remain stable anchors.
    static func nonoverlappingTickIndices(
        positions: [Double],
        maximumTickCount: Int,
        plotWidth: CGFloat,
        labelWidth: CGFloat,
        minimumGap: CGFloat = 4
    ) -> [Int] {
        let candidates = UsageChartMath.tickIndices(
            positions: positions,
            maximumTickCount: maximumTickCount
        )
        guard candidates.count > 2,
              plotWidth.isFinite,
              plotWidth > 0,
              labelWidth.isFinite,
              labelWidth > 0
        else { return candidates }

        let lastPointIndex = positions.count - 1
        let coordinatesAreValid = validPositions(positions, count: positions.count)
        func coordinate(for index: Int) -> CGFloat {
            if coordinatesAreValid {
                return CGFloat(positions[index]) * plotWidth
            }
            guard lastPointIndex > 0 else { return plotWidth / 2 }
            return (CGFloat(index) / CGFloat(lastPointIndex)) * plotWidth
        }
        func interval(for index: Int) -> ClosedRange<CGFloat> {
            let center: CGFloat
            if index == 0 {
                center = labelWidth / 2
            } else if index == lastPointIndex {
                center = plotWidth - (labelWidth / 2)
            } else {
                center = coordinate(for: index)
            }
            return (center - (labelWidth / 2))...(center + (labelWidth / 2))
        }

        guard let first = candidates.first, let last = candidates.last, first != last else {
            return candidates
        }
        let finalInterval = interval(for: last)
        var result = [first]
        var previousInterval = interval(for: first)
        for index in candidates.dropFirst().dropLast() {
            let candidateInterval = interval(for: index)
            guard candidateInterval.lowerBound >= previousInterval.upperBound + minimumGap,
                  candidateInterval.upperBound + minimumGap <= finalInterval.lowerBound
            else { continue }
            result.append(index)
            previousInterval = candidateInterval
        }
        result.append(last)
        return result
    }

    @ViewBuilder
    private func activeSelection(at index: Int, in layout: ChartLayout) -> some View {
        let point = point(for: index, in: layout)

        Path { path in
            path.move(to: CGPoint(x: point.x, y: layout.plotRect.minY))
            path.addLine(to: CGPoint(x: point.x, y: layout.plotRect.maxY))
        }
        .stroke(
            Color.secondary.opacity(0.45),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        .allowsHitTesting(false)

        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 10, height: 10)
            .overlay {
                Circle().stroke(accentColor, lineWidth: 3)
            }
            .position(point)
            .allowsHitTesting(false)
    }

    private func interactionLayer(in layout: ChartLayout) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: layout.plotRect.width, height: layout.plotRect.height)
            // `.position` must stay the outermost modifier. Hover/gesture locations are
            // reported in the local space of the view they're attached to; attaching them
            // before `.position` ties that space unambiguously to this Rectangle's own
            // frame (0...plotWidth). Attaching them after `.position` risked the location
            // instead being reported relative to the full chart bounds (which include the
            // left Y-axis label gutter), shifting every computed index rightward by roughly
            // the gutter width — exactly the "selection lands right of the cursor" bug.
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // A fresh entry (the mouse just arrived, rather than merely continuing
                    // to sit over the chart) always lets hover reclaim the display. Without
                    // this, an arrow-key/accessibility selection could be silently overridden
                    // by residual pointer jitter (e.g. a trackpad palm) that never actually
                    // left the chart, contradicting the "persistent" keyboard selection.
                    if !isHovering {
                        isHovering = true
                        suppressHoverUntilReentry = false
                    }
                    guard !suppressHoverUntilReentry else { return }
                    hoveredIndex = nearestIndex(at: location.x, plotWidth: layout.plotRect.width)
                case .ended:
                    isHovering = false
                    hoveredIndex = nil
                }
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let index = nearestIndex(at: value.location.x, plotWidth: layout.plotRect.width)
                        suppressHoverUntilReentry = false
                        pinnedIndex = index
                        hoveredIndex = index
                        isFocused = true
                    }
            )
            .focusable()
            .focused($isFocused)
            .onMoveCommand(perform: moveSelection)
            .onExitCommand {
                resetSelection()
            }
            .position(x: layout.plotRect.midX, y: layout.plotRect.midY)
    }

    @ViewBuilder
    private func tooltip(at index: Int, in layout: ChartLayout) -> some View {
        let bucket = buckets[index]
        let point = point(for: index, in: layout)
        let tooltipWidth = min(layout.plotRect.width, 146)
        let tooltipHeight: CGFloat = 47
        let x = CGFloat(UsageChartMath.clampedCenter(
            proposed: Double(point.x),
            itemLength: Double(tooltipWidth),
            lowerBound: Double(layout.plotRect.minX),
            upperBound: Double(layout.plotRect.maxX)
        ))
        let proposedY = point.y > layout.plotRect.midY ? point.y - 31 : point.y + 31
        let y = CGFloat(UsageChartMath.clampedCenter(
            proposed: Double(proposedY),
            itemLength: Double(tooltipHeight),
            lowerBound: Double(layout.plotRect.minY),
            upperBound: Double(layout.plotRect.maxY)
        ))

        VStack(alignment: .leading, spacing: 2) {
            Text(tooltipDateLabel(at: index))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("\(UsageFormatting.fullTokens(bucket.tokens, locale: locale)) tokens")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: tooltipWidth, height: tooltipHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
        }
        .position(x: x, y: y)
        .shadow(color: Color.black.opacity(0.16), radius: 4, y: 2)
        .allowsHitTesting(false)
    }

    private func nearestIndex(at x: CGFloat, plotWidth: CGFloat) -> Int? {
        guard plotWidth > 0 else { return nil }
        return UsageChartMath.nearestIndex(
            to: Double(x / plotWidth),
            positions: positions
        )
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !buckets.isEmpty else { return }
        let current = activeIndex ?? buckets.count - 1
        let next: Int
        switch direction {
        case .left, .down:
            next = max(current - 1, 0)
        case .right, .up:
            next = min(current + 1, buckets.count - 1)
        @unknown default:
            return
        }
        hoveredIndex = nil
        suppressHoverUntilReentry = true
        pinnedIndex = next
    }

    private func resetSelection() {
        hoveredIndex = nil
        pinnedIndex = nil
        isHovering = false
        suppressHoverUntilReentry = false
    }

    private func synchronizeExternalSelection(to newIndex: Int?) {
        hoveredIndex = nil
        pinnedIndex = newIndex
        isHovering = false
        suppressHoverUntilReentry = false
    }

    private func point(for index: Int, in layout: ChartLayout) -> CGPoint {
        CGPoint(
            x: xPosition(for: index, in: layout),
            y: yPosition(for: Double(buckets[index].tokens), in: layout)
        )
    }

    private func xPosition(for index: Int, in layout: ChartLayout) -> CGFloat {
        layout.plotRect.minX + (CGFloat(positions[index]) * layout.plotRect.width)
    }

    private func yPosition(for value: Double, in layout: ChartLayout) -> CGFloat {
        let ratio = min(max(value / Double(max(yAxisMax, 1)), 0), 1)
        return layout.plotRect.maxY - (layout.plotRect.height * CGFloat(ratio))
    }

    private func xAxisAlignment(for index: Int) -> Alignment {
        guard buckets.count > 1 else { return .center }
        if index == buckets.startIndex { return .leading }
        if index == buckets.index(before: buckets.endIndex) { return .trailing }
        return .center
    }

    private func xAxisLabelCenter(for index: Int, x: CGFloat, in layout: ChartLayout) -> CGFloat {
        let halfWidth: CGFloat = tickLabelWidth / 2
        guard buckets.count > 1 else {
            return CGFloat(UsageChartMath.clampedCenter(
                proposed: Double(x),
                itemLength: Double(halfWidth * 2),
                lowerBound: Double(layout.plotRect.minX),
                upperBound: Double(layout.plotRect.maxX)
            ))
        }
        if index == buckets.startIndex {
            return layout.plotRect.minX + halfWidth
        }
        if index == buckets.index(before: buckets.endIndex) {
            return layout.plotRect.maxX - halfWidth
        }
        return x
    }

    private static func makeAxisDateFormatter(
        style: UsageChartDateLabelStyle,
        calendar: Calendar,
        locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        switch style {
        case .singleLetterWeekday:
            formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        case .abbreviatedWeekday:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        case .numericMonthDay:
            formatter.setLocalizedDateFormatFromTemplate("Md")
        case .abbreviatedMonthDay:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        case .abbreviatedMonthYear:
            formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        }
        return formatter
    }

    private static func makeTooltipDateFormatter(
        calendar: Calendar,
        locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private func axisDateLabel(at index: Int) -> String {
        formattedDateLabel(at: index, formatter: axisDateFormatter)
    }

    private func tooltipDateLabel(at index: Int) -> String {
        formattedDateLabel(at: index, formatter: tooltipDateFormatter)
    }

    private func formattedDateLabel(at index: Int, formatter: DateFormatter) -> String {
        let bucket = buckets[index]
        guard let date = UsageWindows.date(
            from: bucket.startDate,
            timeZone: calendar.timeZone
        ), Self.foundationCalendar(calendar, represents: bucket.startDate, at: date) else {
            return Self.safeFallbackDateLabel(bucket.startDate)
        }
        return formatter.string(from: date)
    }

    private static func foundationCalendar(
        _ calendar: Calendar,
        represents bucketStartDate: String,
        at date: Date
    ) -> Bool {
        // The bucket contract is proleptic Gregorian regardless of the user's
        // display calendar. Use Gregorian only to detect Foundation's historical
        // cutover mismatch; the caller's calendar still formats valid modern dates.
        var validationCalendar = Calendar(identifier: .gregorian)
        validationCalendar.locale = Locale(identifier: "en_US_POSIX")
        validationCalendar.timeZone = calendar.timeZone
        let components = validationCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return false
        }
        let rendered = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            year,
            month,
            day
        )
        return rendered == bucketStartDate
    }

    private static func safeFallbackDateLabel(_ value: String) -> String {
        UsageWindows.isCanonicalBucketStartDate(value) ? value : "Invalid date"
    }

    var accessibilityValue: String {
        if buckets.isEmpty { return "No activity" }
        if let activeIndex, buckets.indices.contains(activeIndex) {
            let bucket = buckets[activeIndex]
            return "\(tooltipDateLabel(at: activeIndex)), \(UsageFormatting.fullTokens(bucket.tokens, locale: locale)) tokens"
        }
        return hasActivity ? "No point selected" : "No activity"
    }
}

enum UsageChartAxisLabel {
    static func text(_ value: Int64) -> String {
        // Values above the trillion range make localized compact strings wider
        // than the chart's Y-axis gutter. Scientific notation is unambiguous and
        // remains bounded even for Int64.max (for example, "9.2e18").
        if abs(Double(value)) >= 1_000_000_000_000_000 {
            return String(
                format: "%.1e",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(value)
            )
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "e+", with: "e")
                .replacingOccurrences(of: "e0", with: "e")
        }
        return UsageFormatting.axisTokens(value)
    }
}

private struct ChartLayout {
    let plotRect: CGRect

    init(size: CGSize) {
        let leftInset = min(42, max(28, size.width * 0.18))
        let topInset: CGFloat = 18
        let rightInset: CGFloat = 4
        let bottomInset: CGFloat = 25
        plotRect = CGRect(
            x: leftInset,
            y: topInset,
            width: max(size.width - leftInset - rightInset, 1),
            height: max(size.height - topInset - bottomInset, 1)
        )
    }
}
