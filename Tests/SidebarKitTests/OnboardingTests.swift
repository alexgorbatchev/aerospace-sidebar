import AppKit
import PermissionFlow
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct OnboardingModelTests {
    let permissions = FakePermissions()
    let loginItems = FakeLoginItems()

    func model() -> OnboardingModel {
        OnboardingModel(permissions: permissions, loginItems: loginItems)
    }

    @Test func refreshesLiveState() throws {
        let sut = model()
        #expect(!sut.accessibilityGranted && sut.loginItem == .disabled)
        #expect(sut.fullDiskAccess == .notGranted)

        permissions.states = [.accessibility: .granted, .fullDiskAccess: .granted]
        loginItems.status = .enabled
        sut.refresh()

        #expect(sut.accessibilityGranted && sut.loginItem == .enabled)
        #expect(sut.fullDiskAccess == .granted)
    }

    /// Both privacy permissions go through PermissionFlow's drag panel, which flies from the clicked button.
    @Test func guidesThroughPrivacyPanes() {
        let sut = model()
        let button = CGRect(x: 10, y: 20, width: 80, height: 24)

        sut.authorize(.accessibility, from: button)
        sut.authorize(.fullDiskAccess)

        #expect(permissions.authorized == [.accessibility, .fullDiskAccess])
        #expect(permissions.sourceFrames == [button, nil])
        #expect(!sut.accessibilityGranted && sut.fullDiskAccess != .granted)
    }

    @Test func managesLoginItem() {
        let sut = model()

        sut.addLoginItem()
        #expect(sut.loginItem == .enabled)
        #expect(sut.message == "AerospaceSidebar opens at login.")

        sut.removeLoginItem()
        #expect(sut.loginItem == .disabled)
        #expect(sut.message == "AerospaceSidebar no longer opens at login.")

        loginItems.statusAfterRegister = .requiresApproval
        sut.addLoginItem()
        #expect(sut.message?.contains("Login Items") == true)

        sut.openLoginItemsSettings()
        #expect(loginItems.openedSettings == 1)
    }

    @Test func reportsLoginItemFailures() {
        loginItems.error = CocoaError(.fileWriteNoPermission)
        let sut = model()

        sut.addLoginItem()
        #expect(sut.message?.hasPrefix("Cannot add the login item") == true)
        sut.removeLoginItem()
        #expect(sut.message?.hasPrefix("Cannot remove the login item") == true)
    }

    @Test func realLoginItemReportsStatusWithoutRegistering() {
        #expect([.enabled, .disabled, .requiresApproval, .unavailable].contains(MainAppLoginItem().status))
    }
}
