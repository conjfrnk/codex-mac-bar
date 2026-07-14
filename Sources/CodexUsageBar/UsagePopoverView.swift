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

    var scheduleStart: Date { fixedDate ?? Date() }

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

    init(
        viewModel: UsageViewModel,
        viewportSize: NSSize = Self.preferredSize,
        preferences: UserDefaults = .standard,
        initialTimeframe: UsageTimeframe = .thirty,
        launchAtLoginController: LaunchAtLoginController? = nil,
        clock: UsagePresentationClock = .live()
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
            ScrollView(showsIndicators: false) {
                content(now: selectionDate)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
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
            DividerLine()
            launchAtLoginSection
            MenuActionRow(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private var errorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Usage", value: "?", accessibilityValue: "Usage unavailable")
            Text(viewModel.lastError ?? "Codex usage could not be loaded.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DividerLine()
            MenuActionRow(title: "Retry", systemImage: "arrow.clockwise") {
                viewModel.refresh()
            }
            launchAtLoginSection
            MenuActionRow(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
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
                    .font(.system(size: 12, weight: .semibold))
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

            liveRefreshFooter

            DividerLine()

            actionSection
        }
        .onChange(of: historyPageCount) { pageCount in
            dailyHistoryPage = min(max(dailyHistoryPage, 0), max(pageCount - 1, 0))
        }
    }

    /// Only countdown/reset text needs a 30-second cadence. Keeping TimelineView
    /// below the expensive range/chart/history selection avoids sorting a maximal
    /// app-server payload on every countdown tick during a long menu session.
    private func liveRateLimitSection(_ snapshot: UsageSnapshot) -> some View {
        TimelineView(.periodic(from: clock.scheduleStart, by: 30)) { context in
            rateLimitSection(snapshot, now: clock.resolve(context.date))
        }
    }

    private var liveRefreshFooter: some View {
        TimelineView(.periodic(from: clock.scheduleStart, by: 30)) { context in
            refreshFooter(now: clock.resolve(context.date))
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
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
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
                    .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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

    private func refreshFooter(now: Date) -> some View {
        Text("Last successful refresh \(lastUpdatedValue(now: now))")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuActionRow(title: "Refresh", systemImage: "arrow.clockwise") {
                viewModel.refresh()
            }

            launchAtLoginSection

            MenuActionRow(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            LaunchAtLoginRow(
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ),
                isEnabled: launchAtLogin.canToggle
            )

            if let statusText = launchAtLogin.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.leading, 28)
                    .padding(.vertical, 4)
            }
        }
    }

    private func lastUpdatedValue(now: Date) -> String {
        guard let fetchedAt = viewModel.snapshot?.fetchedAt else {
            return "never"
        }
        return Self.elapsedText(since: fetchedAt, now: now)
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
                .font(.system(size: 12, weight: .bold))
            Text("Refresh failed: \(message)")
                .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
    let title: String
    let value: String
    let accessibilityValueOverride: String?

    init(title: String, value: String, accessibilityValue: String? = nil) {
        self.title = title
        self.value = value
        accessibilityValueOverride = accessibilityValue
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueOverride ?? value)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(title) usage unavailable")
                }
                Text(reset)
                    .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Individual usage unavailable")
                }
                Text(reset)
                    .font(.system(size: 12, weight: .semibold))
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

enum RateLimitPresentation {
    static func hasDataQualityIssues(_ response: AccountRateLimitsResponse?) -> Bool {
        response?.decodingIssues.isEmpty == false
    }

    static func resetDescription(
        timestamp: Double?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let date = resetDate(timestamp: timestamp)
        else { return "reset unavailable" }
        let interval = date.timeIntervalSince(now)
        if abs(interval) < 1 { return "resets now" }
        let relative = relativeReset(
            timestamp: timestamp,
            now: now,
            calendar: calendar,
            locale: locale
        )
        guard relative != "n/a" else { return "reset unavailable" }
        // A stale-but-still-open menu can cross the reset boundary. Keep the
        // surrounding verb in the same tense as the formatter's relative value.
        if interval < 0, relative != "now" {
            return "reset \(relative)"
        }
        return "resets \(relative)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "n/a" }
        return UsageFormatting.percent(value)
    }

    static func progress(_ value: Double?) -> Double {
        guard let value = validPercent(value) else { return 0 }
        return min(max(value, 0), 100)
    }

    static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func credits(_ snapshot: CreditsSnapshot) -> String {
        if snapshot.unlimited == true { return "Unlimited" }
        if snapshot.hasCredits == false { return "None" }
        if let balance = snapshot.balance {
            let sanitizedBalance = amount(balance)
            if sanitizedBalance != "n/a" { return sanitizedBalance }
        }
        if snapshot.hasCredits == true { return "Available" }
        let remaining = snapshot.remaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let total = snapshot.total.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let used = snapshot.used.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let remaining, let total, remaining <= total,
           let remainingText = finiteNonnegativeDecimal(remaining),
           let totalText = finiteNonnegativeDecimal(total) {
            return "\(remainingText) / \(totalText) remaining"
        }
        if let remaining, total == nil,
           let remainingText = finiteNonnegativeDecimal(remaining) {
            return "\(remainingText) remaining"
        }
        if let used, let total, used <= total,
           let usedText = finiteNonnegativeDecimal(used),
           let totalText = finiteNonnegativeDecimal(total) {
            return "\(usedText) / \(totalText) used"
        }
        if let used, let usedText = finiteNonnegativeDecimal(used) {
            return "\(usedText) used"
        }
        if let remaining, let remainingText = finiteNonnegativeDecimal(remaining) {
            // Preserve the independently valid field without presenting an
            // inconsistent remaining/total pair as meaningful.
            return "\(remainingText) remaining"
        }
        return "n/a"
    }

    private static func finiteNonnegativeDecimal(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        if value < Double(Int64.max), value.rounded(.towardZero) == value {
            return String(Int64(value))
        }
        return String(
            format: "%.15g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    static func amount(_ value: String?) -> String {
        text(value)
    }

    static func limitReachedStatus(_ value: String?) -> String? {
        guard value != nil else { return nil }
        let sanitized = text(value)
        return sanitized == "n/a" ? "Reported" : sanitized
    }

    static func text(_ value: String?) -> String {
        guard let value else { return "n/a" }
        return BoundedDisplayText.clean(
            value,
            maximumUnicodeScalars: 64,
            emptyFallback: "n/a"
        )
    }

    static func windowDuration(minutes: Int?) -> String {
        UsageFormatting.windowDuration(minutes: minutes)
    }

    static func relativeReset(
        timestamp: Double?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return "n/a" }
        guard let date = resetDate(timestamp: timestamp) else { return "n/a" }
        let formatter = RelativeDateTimeFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func resetDate(timestamp: Double?) -> Date? {
        // The app-server contract defines Unix seconds. Do not silently reinterpret
        // large but valid values as milliseconds.
        guard let seconds = timestamp, seconds.isFinite else { return nil }
        // Foundation formatters are not useful outside the civil Date range.
        guard (0...253_402_300_799).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct DailyUsageRow: View {
    let bucket: DailyUsageBucket
    let locale: Locale

    var body: some View {
        HStack(spacing: 10) {
            Text(bucket.startDate)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(UsageFormatting.fullTokens(bucket.tokens, locale: locale))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
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
/// flanked by small chevron buttons. Styled as a dimmer sibling of `MenuActionRow` —
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
                .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                .font(.system(size: 12, weight: .semibold))
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

private struct LaunchAtLoginRow: View {
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        Toggle("Open at Login", isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 16, weight: .semibold))
            .padding(.vertical, 7)
            .disabled(!isEnabled)
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
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
