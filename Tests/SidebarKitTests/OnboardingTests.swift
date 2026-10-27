import AppKit
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct OnboardingModelTests {
    let platform = FakePlatform()
    let loginItems = FakeLoginItems()
    let performer = RecordingPerformer()

    init() {
        platform.trusted = false
    }

    func model(database: NotificationDatabase = NotificationDatabase(url: URL(fileURLWithPath: "/nonexistent/db"))) -> OnboardingModel {
        OnboardingModel(accessibility: platform, loginItems: loginItems, performer: performer, notificationDatabase: database)
    }

    @Test func refreshesLiveState() throws {
        let fixture = try NotificationDatabaseFixture()
        let sut = model(database: fixture.database)
        #expect(!sut.accessibilityGranted && sut.loginItem == .disabled)
        #expect(!sut.fullDiskAccessGranted)

        platform.trusted = true
        loginItems.status = .enabled
        try fixture.create()
        sut.refresh()

        #expect(sut.accessibilityGranted && sut.loginItem == .enabled)
        #expect(sut.fullDiskAccessGranted)
    }

    @Test func opensFullDiskAccessSettings() {
        let sut = model()

        sut.requestFullDiskAccess()

        #expect(performer.actions == [.open(OnboardingModel.fullDiskAccessSettingsURL)])
        #expect(!sut.fullDiskAccessGranted)
    }

    @Test func requestsAccessibilityWithPromptAndOpensSettings() {
        let sut = model()

        sut.requestAccessibility()

        #expect(platform.promptRequests.contains(true))
        #expect(performer.actions == [.open(SidebarModel.accessibilitySettingsURL)])
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
