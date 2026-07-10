import AppKit
import CodexUsageCore
import CodexUsageUI
import SwiftUI

struct UsagePopoverView: View {
    static let preferredSize = NSSize(width: 300, height: 560)

    @ObservedObject var viewModel: UsageViewModel
    @AppStorage(UsagePreferences.selectedTimeframeKey) private var selectedTimeframeRaw = UsageTimeframe.thirty.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    private let viewportSize: NSSize

    init(
        viewModel: UsageViewModel,
        viewportSize: NSSize = Self.preferredSize
    ) {
        self.viewModel = viewModel
        self.viewportSize = viewportSize
    }

    var body: some View {
        // Scroll position is reset directly on the underlying NSScrollView by AppDelegate,
        // synchronously in `menuWillOpen` before the menu is shown — see
        // `AppDelegate.resetUsageScrollPosition()`. A SwiftUI-side ScrollViewReader.scrollTo
        // was tried here too, but it lands 16pt short of the true top (it aligns an anchor
        // view that sits inside this content's own top padding) and it runs asynchronously,
        // so it was intermittently overriding the correct offset a moment after the menu
        // opened. Don't reintroduce it without accounting for both issues.
        ZStack {
            MenuBackdrop()
            ScrollView(showsIndicators: false) {
                content
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot {
            snapshotContent(snapshot)
        } else if case .loading = viewModel.state {
            loadingContent
        } else {
            errorContent
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Usage", value: "...")
            InfoRow(title: "Status", value: "Fetching account usage")
        }
    }

    private var errorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Usage", value: "?")
            Text(viewModel.lastError ?? "Codex usage could not be loaded.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DividerLine()
            MenuActionRow(title: "Retry", systemImage: "arrow.clockwise") {
                viewModel.refresh()
            }
            MenuActionRow(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private func snapshotContent(_ snapshot: UsageSnapshot) -> some View {
        let range = UsageRange(timeframe: selectedTimeframe, sourceBuckets: snapshot.sortedBuckets)
        let chartBuckets = range.chartBuckets
        let chartMaxTokens = chartBuckets.map(\.tokens).max() ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            header(title: "Usage", value: UsageFormatting.tokens(range.totalTokens))

            TimeframeTabs(selection: selectedTimeframeBinding)
                .padding(.top, 14)

            DividerLine()

            InfoRow(title: selectedTimeframe.heroTitle, value: UsageFormatting.fullTokens(range.totalTokens))
            InfoRow(title: "Scope", value: "All platforms")
            InfoRow(title: "Average/day", value: UsageFormatting.tokens(range.averageDailyTokens))
            InfoRow(title: "Peak day", value: UsageFormatting.tokens(range.peakDailyTokens))
            InfoRow(title: "Active days", value: "\(range.activeDays)")

            DividerLine()

            chartSection(buckets: chartBuckets, maxTokens: chartMaxTokens)

            DividerLine()

            dailySection(range.historyBuckets, title: selectedTimeframe.historyTitle)

            DividerLine()

            rateLimitSection(snapshot)

            refreshFooter

            DividerLine()

            actionSection
        }
    }

    private func header(title: String, value: String) -> some View {
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
    }

    @ViewBuilder
    private func rateLimitSection(_ snapshot: UsageSnapshot) -> some View {
        if let limit = snapshot.rateLimits?.preferredCodexLimit {
            SectionTitle("Rate limits")
                .padding(.bottom, 5)

            if let primary = limit.primary {
                LimitInfoRows(title: "Primary", window: primary)
            }
            if let secondary = limit.secondary {
                LimitInfoRows(title: "Secondary", window: secondary)
            }
            if limit.primary == nil && limit.secondary == nil {
                InfoRow(title: "Window", value: "No active limit")
            }
            let resetCreditCount = snapshot.rateLimits?.rateLimitResetCredits?.availableCount
            InfoRow(title: "Plan", value: limit.planType ?? "n/a")
            InfoRow(
                title: "Reset credits",
                value: resetCreditCount.map { String($0) } ?? "n/a"
            )
        } else {
            SectionTitle("Rate limits")
                .padding(.bottom, 5)
            InfoRow(title: "Window", value: "No data")
        }
    }

    private func chartSection(buckets: [DailyUsageBucket], maxTokens: Int64) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionTitle("Recent activity")
                Spacer()
                Text(maxTokens > 0 ? "\(UsageFormatting.tokens(maxTokens)) peak" : "No usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            UsageLineChart(
                buckets: buckets,
                maxTokens: maxTokens,
                timeframe: selectedTimeframe
            )
            .frame(height: 150)
        }
    }

    private func dailySection(_ buckets: [DailyUsageBucket], title: String) -> some View {
        let rows = Array(buckets.reversed().prefix(6))

        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title)
                .padding(.bottom, 5)
            if rows.isEmpty {
                InfoRow(title: "History", value: "No daily buckets")
            } else {
                ForEach(rows) { bucket in
                    DailyUsageRow(bucket: bucket)
                }
            }
        }
    }

    private var refreshFooter: some View {
        Text("Last refresh \(lastUpdatedValue)")
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

            LaunchAtLoginRow(
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
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

            MenuActionRow(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private var lastUpdatedValue: String {
        guard let fetchedAt = viewModel.snapshot?.fetchedAt else {
            return "never"
        }
        return Self.elapsedText(since: fetchedAt)
    }

    private static func elapsedText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
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
        .accessibilityLabel("Codex Usage")
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
    }
}

private struct LimitInfoRows: View {
    let title: String
    let window: RateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoRow(title: title, value: UsageFormatting.percent(window.usedPercent))
            HStack(spacing: 8) {
                ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                    .tint(tint)
                Text("resets \(UsageFormatting.relativeReset(window.resetDate))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.bottom, 5)
        }
    }

    private var tint: Color {
        if window.usedPercent >= 90 { return .red }
        if window.usedPercent >= 70 { return .orange }
        return .green
    }
}

private struct DailyUsageRow: View {
    let bucket: DailyUsageBucket

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
            Text(UsageFormatting.fullTokens(bucket.tokens))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
        .help("\(bucket.startDate): \(UsageFormatting.fullTokens(bucket.tokens)) tokens")
    }
}

private struct LaunchAtLoginRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Open at Login", isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 16, weight: .semibold))
            .padding(.vertical, 7)
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
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
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
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.24))
            .frame(height: 1)
            .padding(.vertical, 13)
    }
}
