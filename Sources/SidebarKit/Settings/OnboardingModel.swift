import Foundation
import Observation
import PermissionFlow

/// State and actions for Settings › Permissions: Accessibility, Full Disk Access and launch at login.
/// `AeroSpaceSync` covers the AeroSpace step.
@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var accessibilityGranted = false
    /// Whether macOS lets the notification database open, which takes Full Disk Access; `.unknown` while the
    /// database fails for another reason.
    public private(set) var fullDiskAccess = PermissionAuthorizationState.notGranted
    public private(set) var loginItem = LoginItemStatus.unavailable
    /// Result of the last action that removed a permission or changed the login item.
    public private(set) var message: String?
    /// Called after a permission was removed, so whatever depends on it can check it now.
    @ObservationIgnored public var onPermissionsChanged: @MainActor () -> Void = {}

    @ObservationIgnored private let permissions: any PermissionGuiding
    @ObservationIgnored private let loginItems: any LoginItemService

    public init(permissions: any PermissionGuiding, loginItems: any LoginItemService) {
        self.permissions = permissions
        self.loginItems = loginItems
        refresh()
    }

    public func refresh() {
        accessibilityGranted = permissions.state(of: .accessibility) == .granted
        fullDiskAccess = permissions.state(of: .fullDiskAccess)
        loginItem = loginItems.status
    }

    /// Opens the pane in System Settings with PermissionFlow's drag panel, which flies there from
    /// `sourceFrame`, the clicked button's frame on screen. The sidebar never shows macOS's own Accessibility
    /// prompt, which opens the pane without the panel, and macOS has none for Full Disk Access.
    public func authorize(_ pane: PermissionFlowPane, from sourceFrame: CGRect? = nil) {
        permissions.authorize(pane, from: sourceFrame)
        refresh()
    }

    /// Takes AerospaceSidebar off the Accessibility list, for example after an update macOS no longer
    /// recognizes.
    public func removeAccessibility() async {
        await remove(.accessibility, name: "Accessibility")
    }

    /// Takes AerospaceSidebar off the Full Disk Access list.
    public func removeFullDiskAccess() async {
        await remove(.fullDiskAccess, name: "Full Disk Access")
    }

    private func remove(_ pane: PermissionFlowPane, name: String) async {
        let result = await permissions.reset(pane)
        message = result.status == 0
            ? "Removed AerospaceSidebar from \(name)."
            : "Cannot remove AerospaceSidebar from \(name): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        refresh()
        onPermissionsChanged()
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
