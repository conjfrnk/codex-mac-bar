import CodexUsageCore
import SwiftUI

public struct UsageLineChart: View {
    private let buckets: [DailyUsageBucket]
    private let maxTokens: Int64
    private let timeframe: UsageTimeframe

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

    private var positions: [Double] {
        guard buckets.count > 1 else {
            return buckets.isEmpty ? [] : [0.5]
        }
        let dates = buckets.compactMap { UsageWindows.date(from: $0.startDate) }
        guard dates.count == buckets.count,
              let firstDate = dates.first,
              let lastDate = dates.last
        else { return evenlySpacedPositions }

        let duration = lastDate.timeIntervalSince(firstDate)
        guard duration > 0 else { return evenlySpacedPositions }
        return dates.map { $0.timeIntervalSince(firstDate) / duration }
    }

    private var evenlySpacedPositions: [Double] {
        guard buckets.count > 1 else {
            return buckets.isEmpty ? [] : [0.5]
        }
        let denominator = Double(buckets.count - 1)
        return buckets.indices.map { Double($0) / denominator }
    }

    private var axisPolicy: UsageChartAxisPolicy {
        UsageChartAxisPolicy.policy(for: timeframe, spanDays: spanDays)
    }

    private var spanDays: Int? {
        guard let first = buckets.first.flatMap({ UsageWindows.date(from: $0.startDate) }),
              let last = buckets.last.flatMap({ UsageWindows.date(from: $0.startDate) })
        else { return nil }
        return Calendar.current.dateComponents([.day], from: first, to: last).day.map(abs)
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

    public init(
        buckets: [DailyUsageBucket],
        maxTokens: Int64,
        timeframe: UsageTimeframe,
        selectedIndex: Int? = nil
    ) {
        self.buckets = buckets
        self.maxTokens = maxTokens
        self.timeframe = timeframe
        _pinnedIndex = State(initialValue: selectedIndex)
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = ChartLayout(size: proxy.size)

            ZStack(alignment: .topLeading) {
                axes(in: layout)
                usageLine(in: layout)

                if !hasActivity {
                    Text("No activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .position(x: layout.plotRect.midX, y: layout.plotRect.midY)
                        .allowsHitTesting(false)
                } else if buckets.count == 1 {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 7, height: 7)
                        .position(point(for: 0, in: layout))
                        .allowsHitTesting(false)
                }

                if let activeIndex, buckets.indices.contains(activeIndex) {
                    activeSelection(at: activeIndex, in: layout)
                }

                interactionLayer(in: layout)

                if let activeIndex, buckets.indices.contains(activeIndex) {
                    tooltip(at: activeIndex, in: layout)
                }
            }
        }
        .onChange(of: buckets) { _ in
            resetSelection()
        }
        .onChange(of: timeframe) { _ in
            resetSelection()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily token usage chart")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Move the pointer, click, or use the left and right arrow keys to inspect daily values.")
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

            Text(UsageFormatting.axisTokens(value))
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

        let tickIndices = UsageChartMath.tickIndices(
            positions: positions,
            maximumTickCount: axisPolicy.maximumTickCount
        )
        ForEach(tickIndices, id: \.self) { index in
            let x = xPosition(for: index, in: layout)

            Path { path in
                path.move(to: CGPoint(x: x, y: layout.plotRect.maxY))
                path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY + 3))
            }
            .stroke(Color.secondary.opacity(0.40), lineWidth: 1)

            Text(axisLabel(for: buckets[index]))
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
            let samples = UsageChartMath.smoothedSamples(
                values: buckets.map(\.tokens),
                positions: positions
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
                Color.mint,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
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
                Circle().stroke(Color.mint, lineWidth: 3)
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
                hoveredIndex = nil
                pinnedIndex = nil
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
            Text(tooltipDate(for: bucket))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("\(UsageFormatting.fullTokens(bucket.tokens)) tokens")
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
        guard buckets.count > 1 else { return x }
        let halfWidth: CGFloat = tickLabelWidth / 2
        if index == buckets.startIndex {
            return layout.plotRect.minX + halfWidth
        }
        if index == buckets.index(before: buckets.endIndex) {
            return layout.plotRect.maxX - halfWidth
        }
        return x
    }

    private func axisLabel(for bucket: DailyUsageBucket) -> String {
        guard let date = UsageWindows.date(from: bucket.startDate) else { return bucket.startDate }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        switch axisPolicy.dateLabelStyle {
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
        return formatter.string(from: date)
    }

    private func tooltipDate(for bucket: DailyUsageBucket) -> String {
        guard let date = UsageWindows.date(from: bucket.startDate) else { return bucket.startDate }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var accessibilityValue: String {
        guard let activeIndex, buckets.indices.contains(activeIndex) else {
            return buckets.isEmpty ? "No usage data" : "No point selected"
        }
        let bucket = buckets[activeIndex]
        return "\(tooltipDate(for: bucket)), \(UsageFormatting.fullTokens(bucket.tokens)) tokens"
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
