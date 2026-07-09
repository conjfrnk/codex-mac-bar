import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusText: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusText = nil
        case .requiresApproval:
            isEnabled = false
            statusText = "Approve in System Settings"
        case .notRegistered, .notFound:
            isEnabled = false
            statusText = nil
        @unknown default:
            isEnabled = false
            statusText = "Login item status unavailable"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusText = clean(error)
        }
    }

    private func clean(_ error: Error) -> String {
        let message = String(describing: error)
        if message.count <= 140 {
            return message
        }
        return String(message.prefix(137)) + "..."
    }
}
