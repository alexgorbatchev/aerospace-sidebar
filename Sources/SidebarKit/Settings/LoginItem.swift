import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings › General › Login Items.
    case requiresApproval
    case unavailable
}

/// Launch at login; `MainAppLoginItem` is the real implementation. macOS owns this state, so it
/// is read live instead of being stored in `config.toml`.
@MainActor
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Registers this app bundle as a login item with `SMAppService.mainApp`.
@MainActor
public struct MainAppLoginItem: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
