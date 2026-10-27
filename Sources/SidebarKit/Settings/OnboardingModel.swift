import Foundation
import Observation

/// State and actions for the macOS steps of Settings › Setup: Accessibility, Full Disk Access and launch
/// at login. `AeroSpaceSync` covers the AeroSpace step.
@MainActor
@Observable
public final class OnboardingModel {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public private(set) var accessibilityGranted = false
    /// Whether the notification database can be read, which takes Full Disk Access.
    public private(set) var fullDiskAccessGranted = false
    public private(set) var loginItem = LoginItemStatus.unavailable
    /// Result of the last login item action.
    public private(set) var message: String?

    @ObservationIgnored private let accessibility: any AccessibilityPlatform
    @ObservationIgnored private let loginItems: any LoginItemService
    @ObservationIgnored private let performer: any NotificationActionPerforming
    @ObservationIgnored private let notificationDatabase: NotificationDatabase

    public init(
        accessibility: any AccessibilityPlatform,
        loginItems: any LoginItemService,
        performer: any NotificationActionPerforming,
        notificationDatabase: NotificationDatabase
    ) {
        self.accessibility = accessibility
        self.loginItems = loginItems
        self.performer = performer
        self.notificationDatabase = notificationDatabase
        refresh()
    }

    public func refresh() {
        accessibilityGranted = accessibility.isTrusted(prompt: false)
        fullDiskAccessGranted = (try? notificationDatabase.latestRecordID()) != nil
        loginItem = loginItems.status
    }

    /// Opens the Full Disk Access pane, where the user adds the app; macOS offers no prompt for it.
    public func requestFullDiskAccess() {
        performer.perform(.open(Self.fullDiskAccessSettingsURL))
        refresh()
    }

    /// Shows the system prompt when macOS still allows it, and opens the Accessibility pane.
    public func requestAccessibility() {
        _ = accessibility.isTrusted(prompt: true)
        performer.perform(.open(SidebarModel.accessibilitySettingsURL))
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
