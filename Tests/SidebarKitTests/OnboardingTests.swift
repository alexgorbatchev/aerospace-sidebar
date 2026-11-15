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

    /// Each grant flow resets its old entry first, including a Full Disk Access state that cannot be checked.
    @Test func guidesThroughPrivacyPanes() async {
        permissions.states = [.accessibility: .granted, .fullDiskAccess: .unknown]
        let sut = model()
        let button = CGRect(x: 10, y: 20, width: 80, height: 24)
        var announced: [[PermissionFlowPane]] = []
        var grantsBeforeChanges: [[PermissionFlowPane]] = []
        sut.willRemoveAccessibility = { [permissions] in announced.append(permissions.resets) }
        sut.onPermissionsChanged = { [permissions] in grantsBeforeChanges.append(permissions.authorized) }

        await sut.authorize(.accessibility, from: button)
        await sut.authorize(.fullDiskAccess)

        #expect(announced == [[]])
        #expect(permissions.resets == [.accessibility, .fullDiskAccess])
        #expect(grantsBeforeChanges == [[], [.accessibility]])
        #expect(permissions.authorized == [.accessibility, .fullDiskAccess])
        #expect(permissions.sourceFrames == [button, nil])
        #expect(!sut.accessibilityGranted && sut.fullDiskAccess != .granted)
        #expect(!sut.isChangingPermission)
    }

    /// A reset can outlast a second click. Neither another setup nor Remove may reset again while the
    /// first operation is pending, and the grant panel must wait until that reset finishes.
    @Test(arguments: [true, false])
    func waitsForResetAndIgnoresOtherPermissionActions(authorizing: Bool) async {
        let sut = model()
        let button = CGRect(x: 10, y: 20, width: 80, height: 24)
        let (resetGate, releaseReset) = AsyncStream<Void>.makeStream()
        defer { releaseReset.finish() }
        var resetStarts = 0
        permissions.whileResetting = { _ in
            resetStarts += 1
            if resetStarts == 1 {
                for await _ in resetGate {}
            }
        }
        var removalsAnnounced = 0
        sut.willRemoveAccessibility = { removalsAnnounced += 1 }
        let first = Task {
            if authorizing {
                await sut.authorize(.accessibility, from: button)
            } else {
                await sut.removeAccessibility()
            }
        }
        for _ in 0..<1000 where permissions.resets.isEmpty { await Task.yield() }
        guard !permissions.resets.isEmpty else {
            releaseReset.finish()
            await first.value
            Issue.record("The first permission reset did not start.")
            return
        }

        #expect(sut.isChangingPermission)
        #expect(permissions.resets == [.accessibility])
        #expect(permissions.authorized.isEmpty)
        await sut.authorize(.accessibility)
        await sut.authorize(.fullDiskAccess)
        await sut.removeAccessibility()
        await sut.removeFullDiskAccess()
        #expect(permissions.resets == [.accessibility])
        #expect(permissions.authorized.isEmpty)
        #expect(removalsAnnounced == 1)

        releaseReset.finish()
        await first.value
        #expect(!sut.isChangingPermission)
        #expect(permissions.authorized == (authorizing ? [.accessibility] : []))
        #expect(permissions.sourceFrames == (authorizing ? [button] : []))

        await sut.authorize(.fullDiskAccess)
        #expect(permissions.resets == [.accessibility, .fullDiskAccess])
        #expect(permissions.authorized == (authorizing ? [.accessibility, .fullDiskAccess] : [.fullDiskAccess]))
    }

    /// Failed removal leaves the grant UI closed, refreshes live state and permits a later retry.
    @Test(arguments: [(PermissionFlowPane.accessibility, "Accessibility"), (.fullDiskAccess, "Full Disk Access")])
    func reportsFailedSetupResetAndAllowsRetry(pane: PermissionFlowPane, name: String) async {
        let sut = model()
        permissions.states[pane] = .granted
        permissions.resetResult = CommandResult(status: 1, output: " reset failed\n")
        var changes = 0
        sut.onPermissionsChanged = { [permissions] in
            #expect(permissions.authorized.isEmpty)
            changes += 1
        }

        await sut.authorize(pane)

        #expect(permissions.resets == [pane])
        #expect(permissions.authorized.isEmpty)
        #expect(sut.message == "Cannot remove AerospaceSidebar from \(name): reset failed")
        #expect(sut.accessibilityGranted == (pane == .accessibility))
        #expect(sut.fullDiskAccess == (pane == .fullDiskAccess ? .granted : .notGranted))
        #expect(changes == 1)
        #expect(!sut.isChangingPermission)

        permissions.resetResult = CommandResult(status: 0, output: "")
        await sut.authorize(pane)

        #expect(permissions.resets == [pane, pane])
        #expect(permissions.authorized == [pane])
        #expect(!sut.accessibilityGranted && sut.fullDiskAccess == .notGranted)
        #expect(sut.message == "Removed AerospaceSidebar from \(name).")
        #expect(changes == 2)
        #expect(!sut.isChangingPermission)
    }

    /// Removing Accessibility first lets interception move NotificationCenter's windows back while the
    /// permission still allows it; removing Full Disk Access needs no warning. Either removal is reported.
    @Test func announcesRemovingAccessibilityBeforeItIsGone() async {
        permissions.states = [.accessibility: .granted, .fullDiskAccess: .granted]
        let sut = model()
        var announced: [[PermissionFlowPane]] = []
        var changes = 0
        sut.willRemoveAccessibility = { [permissions] in announced.append(permissions.resets) }
        sut.onPermissionsChanged = { changes += 1 }

        await sut.removeFullDiskAccess()
        await sut.removeAccessibility()

        #expect(announced == [[.fullDiskAccess]])
        #expect(permissions.resets == [.fullDiskAccess, .accessibility])
        #expect(changes == 2)
        #expect(!sut.accessibilityGranted)
        #expect(sut.message == "Removed AerospaceSidebar from Accessibility.")
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
