import AppKit
import Combine
import CodexUsageCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let refreshTimerTolerance: TimeInterval = 30

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menuSize = UsagePopoverView.preferredSize
    private let menu = NSMenu()
    private let viewModel = UsageViewModel(client: CodexAppServerClient())
    private let presentationTicker = UsagePresentationTicker()
    private var cancellables = Set<AnyCancellable>()
    private var statusTimeframe = UsagePreferences.selectedTimeframe
    private var refreshTimer: Timer?
    private var usageHostingView: NSView?
    private var cachedUsageScrollView: NSScrollView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()
        bindStatusTitle()
        bindPreferenceChanges()
        startAutoRefresh()
        viewModel.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        presentationTicker.stop()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = viewModel.statusTitle
        button.image = UsageMenuBarIcon.image
        button.imagePosition = .imageLeading
        Self.configureStatusButtonAccessibility(
            button,
            value: viewModel.statusAccessibilityValue
        )
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        menu.removeAllItems()

        let hostingView = NSHostingView(
            rootView: UsagePopoverView(
                viewModel: viewModel,
                presentationTicker: presentationTicker,
                onLocateCodex: { [weak self] in
                    self?.locateCodexExecutable()
                }
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: menuSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let item = NSMenuItem()
        item.view = hostingView
        menu.addItem(item)
        usageHostingView = hostingView
    }

    private func bindStatusTitle() {
        Publishers.CombineLatest(viewModel.$snapshot, viewModel.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    private func bindPreferenceChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let timeframe = UsagePreferences.selectedTimeframe
                guard timeframe != self.statusTimeframe else { return }
                self.statusTimeframe = timeframe
                self.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        button.title = viewModel.statusTitle
        Self.configureStatusButtonAccessibility(
            button,
            value: viewModel.statusAccessibilityValue
        )
    }

    static func configureStatusButtonAccessibility(
        _ button: NSStatusBarButton,
        value: String
    ) {
        button.setAccessibilityLabel("Codex usage")
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp("Open the Codex usage menu")
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Changing app activation while this menu begins tracking can dismiss it immediately.
        viewModel.beginMenuSession()
        presentationTicker.start()
        resetUsageScrollPosition()
        if viewModel.shouldRefresh(maxAge: Self.refreshInterval) {
            viewModel.refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        presentationTicker.stop()
    }

    /// The popover's NSMenuItem view is created once and reused for every open, so its
    /// SwiftUI ScrollView keeps whatever offset it was left at when the menu last closed.
    /// Reset it directly here, synchronously and before the menu becomes visible, rather
    /// than through SwiftUI state — that update path isn't guaranteed to land before the
    /// menu draws, since NSMenu shows itself right after this delegate call returns.
    private func resetUsageScrollPosition() {
        guard let hostingView = usageHostingView else { return }
        let cached = cachedUsageScrollView.flatMap { scrollView in
            Self.isDescendant(scrollView, of: hostingView) ? scrollView : nil
        }
        guard let scrollView = cached ?? Self.findScrollView(in: hostingView) else {
            cachedUsageScrollView = nil
            return
        }
        cachedUsageScrollView = scrollView
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func isDescendant(_ candidate: NSView, of root: NSView) -> Bool {
        var current: NSView? = candidate
        while let view = current {
            if view === root { return true }
            current = view.superview
        }
        return false
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The timer is created before the initial request completes, so an
                // age gate at this exact cadence can miss by a fraction of a second
                // and defer every refresh until the next timer tick. Refresh
                // itself deduplicates any request already in flight.
                self.viewModel.refresh()
            }
        }
        timer.tolerance = Self.refreshTimerTolerance
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func locateCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Locate Codex"
        panel.message = "Choose the Codex CLI executable. It will be validated without being opened."
        panel.prompt = "Use Codex"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UsagePreferences.setCodexExecutable(url)
            viewModel.refresh()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Codex executable not selected"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
