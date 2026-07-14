import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unavailable
}

protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

private struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable(String)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var operationError: String?
    private let service: any LaunchAtLoginServicing

    var isEnabled: Bool {
        state == .enabled || state == .requiresApproval
    }

    var canToggle: Bool {
        if case .unavailable = state { return false }
        return true
    }

    var statusText: String? {
        if let operationError {
            return operationError
        }
        switch state {
        case .disabled, .enabled:
            return nil
        case .requiresApproval:
            return "Approval required in System Settings"
        case let .unavailable(message):
            return message
        }
    }

    init(service: (any LaunchAtLoginServicing)? = nil) {
        self.service = service ?? SystemLaunchAtLoginService()
        refresh()
    }

    func refresh() {
        operationError = nil
        switch service.status {
        case .enabled:
            state = .enabled
        case .requiresApproval:
            // The service is already registered. Showing a checked box lets the
            // user unregister it without accidentally calling register() again.
            state = .requiresApproval
        case .notRegistered:
            state = .disabled
        case .notFound:
            state = .unavailable("Login item is unavailable in this build")
        case .unavailable:
            state = .unavailable("Login item status unavailable")
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard canToggle, enabled != isEnabled else { return }
        operationError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            // A failed register/unregister operation does not make the service
            // permanently unavailable. Preserve the refreshed service state so
            // the user can retry, and present the operation failure separately.
            operationError = clean(error)
        }
    }

    private func clean(_ error: Error) -> String {
        UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 140)
    }
}
