import AppKit
import Darwin

@main
enum CodexUsageBarApp {
    @MainActor
    static func main() {
        // Apply a user-selected executable before any headless command or the
        // app's first refresh constructs an app-server request.
        UsagePreferences.applyPersistedCodexExecutable()

        do {
            if try UsagePopoverRenderer.runIfRequested() {
                return
            }
            if try UsageHealthCheck.runIfRequested() {
                return
            }
        } catch {
            fputs("\(UsageHealthCheck.failureLine(for: error))\n", stderr)
            exit(1)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
