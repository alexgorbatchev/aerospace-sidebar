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
    public private(set) var isChangingPermission = false
    /// Result of the last action that removed a permission or changed the login item.
    public private(set) var message: String?
    /// Called after a permission reset finishes, including a failed attempt, so dependents can check it now.
    @ObservationIgnored public var onPermissionsChanged: @MainActor () -> Void = {}
    /// Called just before the Accessibility permission is removed, while it still lets the sidebar move
    /// NotificationCenter's windows back on screen: without it, a window left off-screen would hide every
    /// later notification until NotificationCenter restarts.
    @ObservationIgnored public var willRemoveAccessibility: @MainActor () -> Void = {}

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

    /// Removes any stale permission entry, then opens System Settings with PermissionFlow's drag panel.
    /// It flies there from `sourceFrame`, the clicked button's frame on screen. The sidebar never shows macOS's own Accessibility
    /// prompt, which opens the pane without the panel, and macOS has none for Full Disk Access.
    public func authorize(_ pane: PermissionFlowPane, from sourceFrame: CGRect? = nil) async {
        guard await remove(pane) else { return }
        permissions.authorize(pane, from: sourceFrame)
        refresh()
    }

    /// Takes AerospaceSidebar off the Accessibility list, for example after an update macOS no longer
    /// recognizes.
    public func removeAccessibility() async {
        await remove(.accessibility)
    }

    /// Takes AerospaceSidebar off the Full Disk Access list.
    public func removeFullDiskAccess() async {
        await remove(.fullDiskAccess)
    }

    @discardableResult
    private func remove(_ pane: PermissionFlowPane) async -> Bool {
        guard !isChangingPermission else { return false }
        isChangingPermission = true
        defer { isChangingPermission = false }
        if pane == .accessibility { willRemoveAccessibility() }
        let name = switch pane {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "Full Disk Access"
        default: pane.rawValue
        }
        let result = await permissions.reset(pane)
        message = result.status == 0
            ? "Removed AerospaceSidebar from \(name)."
            : "Cannot remove AerospaceSidebar from \(name): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        refresh()
        onPermissionsChanged()
        return result.status == 0
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
