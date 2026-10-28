import Foundation
import PermissionFlow

/// Walks the user through granting a macOS privacy permission and reports whether it is granted.
/// `PermissionFlowGuide` is the real one.
@MainActor
public protocol PermissionGuiding {
    func state(of pane: PermissionFlowPane) -> PermissionAuthorizationState
    /// Opens the pane in System Settings, next to a floating panel from which the user drags the app into
    /// the pane's list.
    func authorize(_ pane: PermissionFlowPane)
    /// Takes the app off the pane's list, granted or not.
    func reset(_ pane: PermissionFlowPane) async -> CommandResult
}

/// `PermissionGuiding` through PermissionFlow (jaywcjlove/PermissionFlow). macOS offers no prompt for Full
/// Disk Access and does not list an app there until the user adds it, so the drag panel saves a trip
/// through the + button's file browser; for Accessibility it re-adds the app after an update that macOS no
/// longer recognizes.
@MainActor
public final class PermissionFlowGuide: PermissionGuiding {
    private let controller = PermissionFlowController()
    private let bundleIdentifier: String
    private let run: @Sendable (_ executable: String, _ arguments: [String]) async -> CommandResult

    /// Registers `NotificationDatabaseAccess` as PermissionFlow's Full Disk Access status.
    /// - Parameters:
    ///   - bundleIdentifier: The app whose entries `reset` removes.
    ///   - run: Runs `tccutil`.
    public init(
        notificationDatabase: NotificationDatabase,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        run: @escaping @Sendable (_ executable: String, _ arguments: [String]) async -> CommandResult = SystemCommand.run
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.run = run
        PermissionStatusRegistry.register(provider: NotificationDatabaseAccess(database: notificationDatabase), for: .fullDiskAccess)
    }

    public func state(of pane: PermissionFlowPane) -> PermissionAuthorizationState {
        PermissionStatusRegistry.provider(for: pane).authorizationState()
    }

    public func authorize(_ pane: PermissionFlowPane) {
        controller.authorize(pane: pane)
    }

    /// Resets the app's entry through `tccutil`, the only supported way to revoke a privacy permission.
    public func reset(_ pane: PermissionFlowPane) async -> CommandResult {
        guard let service = Self.tccService(for: pane) else {
            return CommandResult(status: 64, output: "The sidebar does not use the \(pane.rawValue) permission.")
        }
        return await run("/usr/bin/tccutil", ["reset", service, bundleIdentifier])
    }

    /// The TCC service `tccutil` names a permission the sidebar uses by.
    static func tccService(for pane: PermissionFlowPane) -> String? {
        switch pane {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "SystemPolicyAllFiles"
        default: nil
        }
    }
}

/// Full Disk Access as the sidebar needs it: whether the notification database opens. PermissionFlow's own
/// check probes other protected paths, which says nothing about this one.
public struct NotificationDatabaseAccess: PermissionStatusProviding {
    public let database: NotificationDatabase

    public init(database: NotificationDatabase) {
        self.database = database
    }

    public var capability: PermissionStatusCapability { .preflightSupported }

    public func authorizationState() -> PermissionAuthorizationState {
        (try? database.latestRecordID()) != nil ? .granted : .notGranted
    }
}
