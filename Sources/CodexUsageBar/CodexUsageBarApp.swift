import AppKit
import Darwin

@main
enum CodexUsageBarApp {
    @MainActor
    static func main() {
        do {
            if try UsagePopoverRenderer.runIfRequested() {
                return
            }
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
