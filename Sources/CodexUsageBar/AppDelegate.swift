import AppKit
import Combine
import CodexUsageCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 5 * 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menuSize = UsagePopoverView.preferredSize
    private let menu = NSMenu()
    private let viewModel = UsageViewModel(client: CodexAppServerClient())
    private var cancellables = Set<AnyCancellable>()
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
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = viewModel.statusTitle
        button.image = UsageMenuBarIcon.image
        button.imagePosition = .imageLeading
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.removeAllItems()

        let hostingView = NSHostingView(rootView: UsagePopoverView(viewModel: viewModel).preferredColorScheme(.dark))
        hostingView.frame = NSRect(origin: .zero, size: menuSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let item = NSMenuItem()
        item.view = hostingView
        menu.addItem(item)
        usageHostingView = hostingView
    }

    private func bindStatusTitle() {
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusTitle()
                }
            }
            .store(in: &cancellables)
    }

    private func bindPreferenceChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    private func updateStatusTitle() {
        statusItem.button?.title = viewModel.statusTitle
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Changing app activation while this menu begins tracking can dismiss it immediately.
        resetUsageScrollPosition()
        if viewModel.shouldRefresh(maxAge: Self.refreshInterval) {
            viewModel.refresh()
        }
    }

    /// The popover's NSMenuItem view is created once and reused for every open, so its
    /// SwiftUI ScrollView keeps whatever offset it was left at when the menu last closed.
    /// Reset it directly here, synchronously and before the menu becomes visible, rather
    /// than through SwiftUI state — that update path isn't guaranteed to land before the
    /// menu draws, since NSMenu shows itself right after this delegate call returns.
    private func resetUsageScrollPosition() {
        guard let hostingView = usageHostingView,
              let scrollView = cachedUsageScrollView ?? Self.findScrollView(in: hostingView)
        else { return }
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

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.refresh()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }
}
