import AppKit
import CodexUsageCore
import CodexUsageUI
import SwiftUI

struct UsagePresentationClock {
    let fixedDate: Date?
    let calendar: Calendar
    let locale: Locale

    static func live(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> Self {
        Self(fixedDate: nil, calendar: calendar, locale: locale)
    }

    static func fixed(_ date: Date, calendar: Calendar, locale: Locale) -> Self {
        Self(fixedDate: date, calendar: calendar, locale: locale)
    }

    func resolve(_ timelineDate: Date) -> Date {
        fixedDate ?? timelineDate
    }
}

struct DailyHistoryPagination: Equatable {
    static let defaultPageSize = 6

    let page: Int
    let pageCount: Int
    let rowRange: Range<Int>

    init(rowCount: Int, requestedPage: Int, pageSize: Int = defaultPageSize) {
        let safeRowCount = max(0, rowCount)
        let safePageSize = max(1, pageSize)
        let fullPages = safeRowCount / safePageSize
        let partialPage = safeRowCount % safePageSize == 0 ? 0 : 1
        pageCount = max(1, fullPages + partialPage)
        page = min(max(requestedPage, 0), pageCount - 1)
        let start = min(page * safePageSize, safeRowCount)
        let availableRows = safeRowCount - start
        let end = start + min(safePageSize, availableRows)
        rowRange = start..<end
    }
}

struct UsagePopoverView: View {
    static let preferredSize = NSSize(width: 300, height: 560)

    @ObservedObject var viewModel: UsageViewModel
    @AppStorage private var selectedTimeframeRaw: String
    @StateObject private var launchAtLogin: LaunchAtLoginController
    @State private var dailyHistoryPage = 0
    private let viewportSize: NSSize
    private let clock: UsagePresentationClock
    private let presentationTicker: UsagePresentationTicker
    private let onLocateCodex: () -> Void

    init(
        viewModel: UsageViewModel,
        viewportSize: NSSize = Self.preferredSize,
        preferences: UserDefaults = .standard,
        initialTimeframe: UsageTimeframe = .thirty,
        launchAtLoginController: LaunchAtLoginController? = nil,
        clock: UsagePresentationClock = .live(),
        presentationTicker: UsagePresentationTicker? = nil,
        onLocateCodex: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.viewportSize = viewportSize
        self.clock = clock
        _selectedTimeframeRaw = AppStorage(
            wrappedValue: initialTimeframe.rawValue,
            UsagePreferences.selectedTimeframeKey,
            store: preferences
        )
        _launchAtLogin = StateObject(
            wrappedValue: launchAtLoginController ?? LaunchAtLoginController()
        )
        self.presentationTicker = presentationTicker ?? UsagePresentationTicker(
            now: { clock.fixedDate ?? Date() }
        )
        self.onLocateCodex = onLocateCodex
    }

    var body: some View {
        // Scroll position is reset directly on the underlying NSScrollView by AppDelegate,
        // synchronously in `menuWillOpen` before the menu is shown — see
        // `AppDelegate.resetUsageScrollPosition()`. A SwiftUI-side ScrollViewReader.scrollTo
        // was tried here too, but it lands 16pt short of the true top (it aligns an anchor
        // view that sits inside this content's own top padding) and it runs asynchronously,
        // so it was intermittently overriding the correct offset a moment after the menu
        // opened. Don't reintroduce it without accounting for both issues.
        let selectionDate = clock.resolve(Date())
        ZStack {
            MenuBackdrop()
            VStack(spacing: 0) {
                ScrollView(showsIndicators: true) {
                    content(now: selectionDate)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }

                UsagePopoverFooter(
                    launchAtLogin: launchAtLogin,
                    presentationTicker: presentationTicker,
                    lastSuccessfulRefresh: viewModel.snapshot?.fetchedAt,
                    showsLocateCodex: viewModel.lastError != nil,
                    onRefresh: viewModel.refresh,
                    onLocateCodex: onLocateCodex,
                    onQuit: { NSApp.terminate(nil) }
                )
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .onAppear {
            launchAtLogin.refresh()
        }
        .onChange(of: selectedTimeframe) { _ in
            dailyHistoryPage = 0
        }
        .onChange(of: viewModel.menuSessionID) { _ in
            // The login item may have been approved or removed in System Settings
            // while the menu was closed, so every menu session starts from reality.
            launchAtLogin.refresh()
            dailyHistoryPage = 0
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let snapshot = viewModel.snapshot {
            snapshotContent(snapshot, now: now)
        } else if case .loading = viewModel.state {
            loadingContent
        } else {
            errorContent
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Usage", value: "...", accessibilityValue: "Loading usage")
            InfoRow(title: "Status", value: "Fetching account usage")
        }
    }

    private var errorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Usage", value: "?", accessibilityValue: "Usage unavailable")
            Text(viewModel.lastError ?? "Codex usage could not be loaded.")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func snapshotContent(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let selection = UsageDisplaySelection(
            snapshot: snapshot,
            timeframe: selectedTimeframe,
            now: now,
            calendar: clock.calendar
        )
        let range = selection.range
        let chartBuckets = range.chartBuckets
        let historyBuckets = range.historyBuckets
        let historyPageCount = DailyHistoryPagination(
            rowCount: historyBuckets.count,
            requestedPage: dailyHistoryPage
        ).pageCount
        let chartMaxTokens = chartBuckets.map(\.tokens).max() ?? 0
        let compactTotal = selection.totalTokens.map(UsageFormatting.tokens) ?? "n/a"
        let fullTotal = selection.totalTokens.map {
            UsageFormatting.fullTokens($0, locale: clock.locale)
        } ?? "n/a"

        return VStack(alignment: .leading, spacing: 0) {
            header(
                title: "Usage",
                value: compactTotal,
                accessibilityValue: selection.totalTokens.map { "\(UsageFormatting.fullTokens($0, locale: clock.locale)) tokens" }
                    ?? "Token total unavailable"
            )

            if let error = viewModel.lastError {
                StaleSnapshotBanner(message: error)
                    .padding(.top, 12)
            } else if case .loading = viewModel.state {
                Text("Refreshing usage…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .accessibilityLabel("Refreshing usage")
            }

            TimeframeTabs(selection: selectedTimeframeBinding)
                .padding(.top, 14)

            DividerLine()

            InfoRow(
                title: selectedTimeframe.heroTitle,
                value: fullTotal,
                accessibilityValue: selection.totalTokens.map { "\(UsageFormatting.fullTokens($0, locale: clock.locale)) tokens" }
                    ?? "Token total unavailable"
            )
            InfoRow(title: "Scope", value: "All platforms")
            InfoRow(
                title: "Average/day",
                value: selection.averageDailyTokens.map(UsageFormatting.tokens) ?? "n/a",
                accessibilityValue: selection.averageDailyTokens.map { "\(UsageFormatting.fullTokens($0, locale: clock.locale)) tokens per day" }
                    ?? "Unavailable"
            )
            InfoRow(
                title: "Peak day",
                value: selection.peakDailyTokens.map(UsageFormatting.tokens) ?? "n/a",
                accessibilityValue: selection.peakDailyTokens.map { "\(UsageFormatting.fullTokens($0, locale: clock.locale)) tokens" }
                    ?? "Unavailable"
            )
            InfoRow(title: "Active days", value: selection.activeDays.map(String.init) ?? "n/a")
            if !selection.hasDailyData {
                InfoRow(title: "Daily data", value: "Unavailable")
            } else if selection.isDailyHistoryPartial {
                InfoRow(title: "Daily history", value: "Partial")
            }
            if range.rejectedBucketCount > 0 {
                InfoRow(
                    title: "Data quality",
                    value: "\(range.rejectedBucketCount) invalid daily bucket(s) omitted"
                )
            }
            if range.didOverflow {
                InfoRow(title: "Data quality", value: "Daily total exceeds supported range")
            }
            if selection.hasUnreconciledAllTimeTotal {
                InfoRow(title: "Data quality", value: "All-time total unavailable")
            }

            DividerLine()

            chartSection(
                buckets: chartBuckets,
                positions: range.chartPositions,
                maxTokens: chartMaxTokens,
                hasDailyData: selection.hasDailyData,
                hasSaturatedDailyValues: selection.hasSaturatedDailyValues,
                isPartialHistory: selection.isDailyHistoryPartial
            )

            DividerLine()

            dailySection(
                historyBuckets,
                title: selection.isDailyHistoryPartial
                    ? "Available active-day history"
                    : selectedTimeframe.historyTitle,
                hasDailyData: selection.hasDailyData,
                hasSaturatedDailyValues: selection.hasSaturatedDailyValues
            )

            DividerLine()

            liveRateLimitSection(snapshot)
        }
        .onChange(of: historyPageCount) { pageCount in
            dailyHistoryPage = min(max(dailyHistoryPage, 0), max(pageCount - 1, 0))
        }
    }

    /// Only countdown/reset text observes the shared presentation ticker. Keeping
    /// that observation below expensive range/chart/history selection avoids
    /// sorting a maximal app-server payload on every presentation tick.
    private func liveRateLimitSection(_ snapshot: UsageSnapshot) -> some View {
        LivePresentationValue(ticker: presentationTicker) { date in
            rateLimitSection(snapshot, now: clock.resolve(date))
        }
    }

    private func header(
        title: String,
        value: String,
        accessibilityValue: String
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            CodexUsageLogo()
                .frame(width: 34, height: 34)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private func rateLimitSection(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let hasDataQualityIssues = RateLimitPresentation.hasDataQualityIssues(snapshot.rateLimits)
        let rawResetCreditCount: Int64? = snapshot.rateLimits?.rateLimitResetCredits?.availableCount
        let resetCreditCount = rawResetCreditCount.flatMap { $0 >= 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 0) {
            if let limit = snapshot.rateLimits?.preferredCodexLimit {
                SectionTitle("Rate limits")
                    .padding(.bottom, 5)

                if let primary = limit.primary {
                    LimitInfoRows(
                        title: "Primary",
                        window: primary,
                        now: now,
                        calendar: clock.calendar,
                        locale: clock.locale
                    )
                }
                if let secondary = limit.secondary {
                    LimitInfoRows(
                        title: "Secondary",
                        window: secondary,
                        now: now,
                        calendar: clock.calendar,
                        locale: clock.locale
                    )
                }
                if let individual = limit.individualLimit {
                    IndividualLimitInfoRows(
                        limit: individual,
                        now: now,
                        calendar: clock.calendar,
                        locale: clock.locale
                    )
                }
                if limit.primary == nil && limit.secondary == nil && limit.individualLimit == nil {
                    InfoRow(
                        title: "Window",
                        value: hasDataQualityIssues ? "Some data unavailable" : "No active limit"
                    )
                }
                InfoRow(title: "Plan", value: RateLimitPresentation.text(limit.planType))
                if let credits = limit.credits {
                    InfoRow(title: "Credits", value: RateLimitPresentation.credits(credits))
                }
                if let reachedStatus = RateLimitPresentation.limitReachedStatus(
                    limit.rateLimitReachedType
                ) {
                    InfoRow(title: "Limit reached", value: reachedStatus)
                }
            } else {
                SectionTitle("Rate limits")
                    .padding(.bottom, 5)
                InfoRow(title: "Window", value: "No data")
            }
            InfoRow(
                title: "Reset credits",
                value: resetCreditCount.map { String($0) } ?? "n/a"
            )
            if hasDataQualityIssues {
                InfoRow(title: "Data quality", value: "Some rate-limit fields were omitted")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartSection(
        buckets: [DailyUsageBucket],
        positions: [Double],
        maxTokens: Int64,
        hasDailyData: Bool,
        hasSaturatedDailyValues: Bool,
        isPartialHistory: Bool
    ) -> some View {
        let activityTitle = isPartialHistory
            ? "Available activity"
            : (selectedTimeframe == .all ? "All-time activity" : "Recent activity")
        let activityStatus: String
        if !hasDailyData {
            activityStatus = "Daily data unavailable"
        } else if hasSaturatedDailyValues {
            activityStatus = "Data out of range"
        } else {
            activityStatus = maxTokens > 0 ? "\(UsageFormatting.tokens(maxTokens)) peak" : "No usage"
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionTitle(activityTitle)
                Spacer()
                Text(activityStatus)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if hasDailyData && !hasSaturatedDailyValues {
                UsageLineChart(
                    buckets: buckets,
                    maxTokens: maxTokens,
                    timeframe: selectedTimeframe,
                    positions: positions,
                    calendar: clock.calendar,
                    locale: clock.locale
                )
                .id(viewModel.menuSessionID)
                .frame(height: 150)
            } else {
                Text(
                    hasSaturatedDailyValues
                        ? "Daily totals exceed the supported range"
                        : "Daily data unavailable"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .accessibilityLabel(
                        hasSaturatedDailyValues
                            ? "Daily usage chart unavailable because totals exceed the supported range"
                            : "Daily usage chart unavailable"
                    )
            }
        }
    }

    private func dailySection(
        _ buckets: [DailyUsageBucket],
        title: String,
        hasDailyData: Bool,
        hasSaturatedDailyValues: Bool
    ) -> some View {
        // `buckets` is chronologically ascending (oldest first); reverse once so index 0
        // is always the newest row, matching the pager's page-0-is-newest convention.
        let allRows = Array(buckets.reversed())
        let pagination = DailyHistoryPagination(
            rowCount: allRows.count,
            requestedPage: dailyHistoryPage
        )
        let rows = Array(allRows[pagination.rowRange])

        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title)
                .padding(.bottom, 5)

            if hasSaturatedDailyValues {
                InfoRow(title: "History", value: "Values exceed supported range")
            } else if !hasDailyData {
                InfoRow(title: "History", value: "Daily data unavailable")
            } else if rows.isEmpty {
                InfoRow(title: "History", value: "No active days")
            } else {
                ForEach(rows) { bucket in
                    DailyUsageRow(bucket: bucket, locale: clock.locale)
                }
            }

            if !hasSaturatedDailyValues && pagination.pageCount > 1 {
                DailyHistoryPager(
                    page: pagination.page,
                    pageCount: pagination.pageCount,
                    onPrevious: { dailyHistoryPage = max(0, pagination.page - 1) },
                    onNext: {
                        dailyHistoryPage = min(pagination.pageCount - 1, pagination.page + 1)
                    }
                )
            }
        }
    }

    nonisolated static func elapsedText(since date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite else { return "unknown" }
        guard interval >= 0 else { return "clock changed" }
        // Keep the Double-to-Int conversion comfortably inside the representable
        // boundary (Double(Int.max) itself rounds up on 64-bit platforms).
        let seconds = Int(min(max(interval, 0), Double(Int.max / 2)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private var selectedTimeframe: UsageTimeframe {
        UsageTimeframe(rawValue: selectedTimeframeRaw) ?? .thirty
    }

    private var selectedTimeframeBinding: Binding<UsageTimeframe> {
        Binding(
            get: { selectedTimeframe },
            set: { timeframe in
                selectedTimeframeRaw = timeframe.rawValue
                viewModel.timeframePreferenceChanged()
            }
        )
    }
}

private struct MenuBackdrop: View {
    var body: some View {
        Color.clear
    }
}

private struct StaleSnapshotBanner: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text("Showing last successful usage")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
                .font(.caption.weight(.bold))
            Text("Refresh failed: \(message)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Showing last successful usage. Refresh failed: \(message)")
    }
}

/// Matches the app icon's motif: a usage-ring gauge with a terminal chevron nested inside it,
/// on the same dark rounded-square tile used for the .icns.
private struct CodexUsageLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.24, blue: 0.29),
                                Color(red: 0.10, green: 0.11, blue: 0.14),
                                Color(red: 0.035, green: 0.04, blue: 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                UsageRingMark()
                    .frame(width: size * 0.62, height: size * 0.62)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

private struct UsageRingMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: side * 0.185, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.73)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.42, green: 0.97, blue: 0.86),
                                Color(red: 0.20, green: 0.72, blue: 0.99),
                                Color(red: 0.32, green: 0.40, blue: 0.98)
                            ],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(263)
                        ),
                        style: StrokeStyle(lineWidth: side * 0.185, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                chevron(side: side)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: side * 0.099, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.35), radius: side * 0.03, y: -side * 0.02)
            }
        }
    }

    private func chevron(side: CGFloat) -> Path {
        let height = side * 0.329
        let reach = side * 0.178
        let xOffset = -side * 0.03
        let center = CGPoint(x: side / 2 + xOffset, y: side / 2)
        var path = Path()
        path.move(to: CGPoint(x: center.x - reach / 2, y: center.y - height / 2))
        path.addLine(to: CGPoint(x: center.x + reach / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x - reach / 2, y: center.y + height / 2))
        return path
    }
}

private struct TimeframeTabs: View {
    @Binding var selection: UsageTimeframe

    var body: some View {
        HStack(spacing: 4) {
            ForEach(UsageTimeframe.allCases) { timeframe in
                Button {
                    selection = timeframe
                } label: {
                    Text(timeframe.shortTitle)
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == timeframe ? Color.primary : Color.secondary)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == timeframe ? Color.primary.opacity(0.10) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == timeframe ? .isSelected : [])
            }
        }
    }
}

private struct InfoRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let value: String
    let accessibilityValueOverride: String?

    init(title: String, value: String, accessibilityValue: String? = nil) {
        self.title = title
        self.value = value
        accessibilityValueOverride = accessibilityValue
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    valueText
                        .multilineTextAlignment(.leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Spacer(minLength: 10)
                    valueText
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueOverride ?? value)
    }

    private var titleText: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .minimumScaleFactor(0.76)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LimitInfoRows: View {
    let title: String
    let window: RateLimitWindow
    let now: Date
    let calendar: Calendar
    let locale: Locale

    var body: some View {
        let reset = RateLimitPresentation.resetDescription(
            timestamp: window.resetsAt,
            now: now,
            calendar: calendar,
            locale: locale
        )
        VStack(alignment: .leading, spacing: 0) {
            InfoRow(title: title, value: RateLimitPresentation.percent(window.usedPercent))
            InfoRow(
                title: "\(title) window",
                value: RateLimitPresentation.windowDuration(minutes: window.windowDurationMins)
            )
            HStack(spacing: 8) {
                if RateLimitPresentation.validPercent(window.usedPercent) != nil {
                    ProgressView(value: RateLimitPresentation.progress(window.usedPercent), total: 100)
                        .tint(tint)
                        .accessibilityLabel("\(title) usage")
                        .accessibilityValue(RateLimitPresentation.percent(window.usedPercent))
                } else {
                    Text("Usage unavailable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(title) usage unavailable")
                }
                Text(reset)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.bottom, 5)
        }
    }

    private var tint: Color {
        let percent = RateLimitPresentation.progress(window.usedPercent)
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}

private struct IndividualLimitInfoRows: View {
    let limit: SpendControlLimitSnapshot
    let now: Date
    let calendar: Calendar
    let locale: Locale

    var body: some View {
        let reset = RateLimitPresentation.resetDescription(
            timestamp: limit.resetsAt,
            now: now,
            calendar: calendar,
            locale: locale
        )
        VStack(alignment: .leading, spacing: 0) {
            InfoRow(title: "Individual", value: RateLimitPresentation.percent(limit.usedPercent))
            if limit.used != nil || limit.limit != nil {
                InfoRow(title: "Individual used", value: RateLimitPresentation.amount(limit.used))
                InfoRow(title: "Individual limit", value: RateLimitPresentation.amount(limit.limit))
            }
            HStack(spacing: 8) {
                if RateLimitPresentation.validPercent(limit.usedPercent) != nil {
                    ProgressView(value: RateLimitPresentation.progress(limit.usedPercent), total: 100)
                        .tint(tint)
                        .accessibilityLabel("Individual usage")
                        .accessibilityValue(RateLimitPresentation.percent(limit.usedPercent))
                } else {
                    Text("Usage unavailable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Individual usage unavailable")
                }
                Text(reset)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.bottom, 5)
        }
    }

    private var tint: Color {
        let percent = RateLimitPresentation.progress(limit.usedPercent)
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}

private struct DailyUsageRow: View {
    let bucket: DailyUsageBucket
    let locale: Locale

    var body: some View {
        HStack(spacing: 10) {
            Text(bucket.startDate)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(UsageFormatting.fullTokens(bucket.tokens, locale: locale))
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
        .help("\(bucket.startDate): \(UsageFormatting.fullTokens(bucket.tokens, locale: locale)) tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bucket.startDate)
        .accessibilityValue("\(UsageFormatting.fullTokens(bucket.tokens, locale: locale)) tokens")
    }
}

/// A minimal, quiet pager for the paginated daily-history section: "Page X of Y"
/// flanked by small chevron buttons. Styled as a quiet sibling of the footer actions —
/// same plain-button + SF Symbol language, but secondary-toned, compact, and centered
/// so it reads as a footnote under the row list rather than a new call to action.
/// Direction convention: page 0 is the newest rows. The left/back chevron moves
/// toward newer (decrements), the right/forward chevron moves toward older
/// (increments); whichever side has nothing further in that direction is dimmed
/// and disabled rather than wrapping or silently doing nothing.
private struct DailyHistoryPager: View {
    let page: Int
    let pageCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void

    private var isAtNewest: Bool { page <= 0 }
    private var isAtOldest: Bool { page >= pageCount - 1 }

    var body: some View {
        HStack(spacing: 8) {
            pagerButton(systemImage: "chevron.left", isEnabled: !isAtNewest, label: "Newer", action: onPrevious)

            Spacer(minLength: 0)

            Text("Page \(page + 1) of \(pageCount)")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            pagerButton(systemImage: "chevron.right", isEnabled: !isAtOldest, label: "Older", action: onNext)
        }
        .padding(.top, 6)
    }

    private func pagerButton(
        systemImage: String,
        isEnabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(isEnabled ? 1 : 0.32)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.24))
            .frame(height: 1)
            .padding(.vertical, 13)
            .accessibilityHidden(true)
    }
}
