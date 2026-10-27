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
        #expect(!sut.fullDiskAccessGranted)

        permissions.states = [.accessibility: .granted, .fullDiskAccess: .granted]
        loginItems.status = .enabled
        sut.refresh()

        #expect(sut.accessibilityGranted && sut.loginItem == .enabled)
        #expect(sut.fullDiskAccessGranted)
    }

    /// Both privacy permissions go through PermissionFlow's drag panel.
    @Test func guidesThroughPrivacyPanes() {
        let sut = model()

        sut.requestAccessibility()
        sut.requestFullDiskAccess()

        #expect(permissions.authorized == [.accessibility, .fullDiskAccess])
        #expect(!sut.accessibilityGranted && !sut.fullDiskAccessGranted)
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
