import AppKit
import Combine
import Foundation
import SwiftUI

/// One scheduler drives every time-relative value in the reused menu view. The
/// app delegate starts it only while the menu is open, so a hidden menu does not
/// keep invalidating presentation-only text.
@MainActor
final class UsagePresentationTicker: ObservableObject {
    static let cadence: TimeInterval = 30
    static let tolerance: TimeInterval = 5

    @Published private(set) var date: Date

    private let now: () -> Date
    private var timer: Timer?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        date = now()
    }

    var isRunning: Bool {
        timer != nil
    }

    func start() {
        updateDate()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDate()
            }
        }
        timer.tolerance = Self.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateDate() {
        date = now()
    }
}

/// Observes the shared ticker at the smallest possible boundary. Parents that
/// perform usage aggregation and chart preparation are not recomputed on every
/// presentation tick.
struct LivePresentationValue<Content: View>: View {
    @ObservedObject var ticker: UsagePresentationTicker
    private let content: (Date) -> Content

    init(
        ticker: UsagePresentationTicker,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        self.ticker = ticker
        self.content = content
    }

    var body: some View {
        content(ticker.date)
    }
}

struct UsagePopoverFooter: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    let presentationTicker: UsagePresentationTicker

    let lastSuccessfulRefresh: Date?
    let showsLocateCodex: Bool
    let onRefresh: () -> Void
    let onLocateCodex: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.24))
                .frame(height: 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 14) {
                    FooterActionButton(
                        title: "Refresh",
                        systemImage: "arrow.clockwise",
                        action: onRefresh
                    )
                    Spacer(minLength: 12)
                    FooterActionButton(
                        title: "Quit",
                        systemImage: "power",
                        action: onQuit
                    )
                }

                if showsLocateCodex {
                    FooterActionButton(
                        title: "Locate Codex…",
                        systemImage: "folder",
                        action: onLocateCodex
                    )
                }

                Toggle(
                    "Open at Login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.body.weight(.semibold))
                .padding(.vertical, 5)
                .disabled(!launchAtLogin.canToggle)

                if launchAtLogin.requiresApproval {
                    Text("Approval required in System Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FooterActionButton(
                        title: "Open Login Items Settings…",
                        systemImage: "gearshape",
                        action: launchAtLogin.openSystemSettingsLoginItems
                    )
                } else if let statusText = launchAtLogin.statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !launchAtLogin.requiresApproval && !showsLocateCodex {
                    LivePresentationValue(ticker: presentationTicker) { date in
                        Text(lastRefreshText(now: date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func lastRefreshText(now: Date) -> String {
        guard let lastSuccessfulRefresh else {
            return "Last successful refresh never"
        }
        return "Last successful refresh \(UsagePopoverView.elapsedText(since: lastSuccessfulRefresh, now: now))"
    }
}

private struct FooterActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
