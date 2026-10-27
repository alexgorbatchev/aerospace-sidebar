import Foundation
import Observation
import PermissionFlow

/// State and actions for the macOS steps of Settings › Setup: Accessibility, Full Disk Access and launch
/// at login. `AeroSpaceSync` covers the AeroSpace step.
@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var accessibilityGranted = false
    /// Whether the notification database can be read, which takes Full Disk Access.
    public private(set) var fullDiskAccessGranted = false
    public private(set) var loginItem = LoginItemStatus.unavailable
    /// Result of the last login item action.
    public private(set) var message: String?

    @ObservationIgnored private let permissions: any PermissionGuiding
    @ObservationIgnored private let loginItems: any LoginItemService

    public init(permissions: any PermissionGuiding, loginItems: any LoginItemService) {
        self.permissions = permissions
        self.loginItems = loginItems
        refresh()
    }

    public func refresh() {
        accessibilityGranted = permissions.state(of: .accessibility) == .granted
        fullDiskAccessGranted = permissions.state(of: .fullDiskAccess) == .granted
        loginItem = loginItems.status
    }

    /// Opens the Full Disk Access pane with the drag panel; macOS offers no prompt for it.
    public func requestFullDiskAccess() {
        permissions.authorize(.fullDiskAccess)
        refresh()
    }

    /// Opens the Accessibility pane with the drag panel. The prompt that adds the app to the pane's list
    /// comes from `NotificationCenterMonitor` at launch.
    public func requestAccessibility() {
        permissions.authorize(.accessibility)
        refresh()
    }

    public func addLoginItem() {
        do {
            try loginItems.register()
            message = loginItems.status == .requiresApproval
                ? "Allow AerospaceSidebar in System Settings › General › Login Items."
                : "AerospaceSidebar opens at login."
        } catch {
            message = "Cannot add the login item: \(error.localizedDescription)"
        }
        refresh()
    }

    public func removeLoginItem() {
        do {
            try loginItems.unregister()
            message = "AerospaceSidebar no longer opens at login."
        } catch {
            message = "Cannot remove the login item: \(error.localizedDescription)"
        }
        refresh()
    }

    public func openLoginItemsSettings() {
        loginItems.openSystemSettings()
    }
}
